import SwiftData
import SwiftUI

enum PhoneTab: String, CaseIterable, Identifiable {
    case home, tasks, calendar
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .home: "house"
        case .tasks: "checkmark.circle"
        case .calendar: "calendar"
        }
    }
    var selectedSymbol: String {
        switch self {
        case .home: "house.fill"
        case .tasks: "checkmark.circle.fill"
        // SF Symbols has a calendar glyph but no calendar.fill variant.
        case .calendar: "calendar"
        }
    }
}

enum PhoneRoute: Hashable {
    case allNotes(tag: String?)
    case note(UUID)
    case task(UUID)
    case canvases
    case canvas(UUID)
    case settings
}

enum PhoneTasksTab: String, CaseIterable, Identifiable {
    case now, later, done
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .now: "checkmark.circle"
        case .later: "circle.dashed"
        case .done: "checkmark.circle.fill"
        }
    }
}

/// The main screens and pushed destinations share one navigation stack. The
/// bottom controls use native material; content stays on an unboxed surface.
struct PhoneShell: View {
    @StateObject private var state: PhoneAppState
    private let syntheticCalendar: Bool
    @State private var tab: PhoneTab = .home
    @State private var path: [PhoneRoute] = []
    @State private var tasksTab: PhoneTasksTab = .now
    @State private var selectedTag: String?
    @State private var collapsed: Set<String> = []
    @State private var expandedTags: Set<String> = []
    @State private var searchPresented = false
    @State private var capturePresented = false
    @State private var captureDraft = PhoneCaptureDraft()
    @State private var captureCommitted = false
    @State private var captureConfirmation: String?
    @ScaledMetric(relativeTo: .largeTitle) private var pageTitleSize: CGFloat = 34

    init(container: ModelContainer, syntheticCalendar: Bool) {
        _state = StateObject(wrappedValue: PhoneAppState(container: container))
        self.syntheticCalendar = syntheticCalendar
    }

    var body: some View {
        NavigationStack(path: $path) {
            screen(root: true) { rootContent }
                .navigationDestination(for: PhoneRoute.self) { route in
                    if case .canvas = route {
                        // Draw owns its own tool and title chrome; the ordinary
                        // page header and tab dock would cover its drawing area.
                        destination(route).toolbar(.hidden, for: .navigationBar)
                    } else {
                        screen(root: false, route: route) { destination(route) }
                    }
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isCanvasOpen { dock }
        }
        .background(Color(uiColor: .systemBackground))
        .sheet(isPresented: $searchPresented) {
            PhoneSearchWaveSheet(state: state) { route in
                searchPresented = false
                DispatchQueue.main.async { path.append(route) }
            }
        }
        .sheet(isPresented: $capturePresented, onDismiss: {
            if captureCommitted {
                if captureDraft.kind == .note { captureConfirmation = "Added to Notes" }
                captureDraft = PhoneCaptureDraft()
                captureCommitted = false
            }
        }) {
            PhoneCaptureSheet(state: state, draft: $captureDraft) {
                // Drive the presentation binding explicitly after a successful
                // transaction; the draft resets only when the sheet has closed.
                captureCommitted = true
                capturePresented = false
            }
        }
        .task(id: captureConfirmation) {
            guard captureConfirmation != nil else { return }
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            captureConfirmation = nil
        }
        .alert("Could not save", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "The operation could not be completed.")
        }
        .phoneLocalPreferences()
    }

    private var isCanvasOpen: Bool {
        guard let last = path.last else { return false }
        if case .canvas = last { return true }
        return false
    }

    private func screen<Content: View>(root: Bool, route: PhoneRoute? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                if root {
                    Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                } else {
                    Button {
                        if !path.isEmpty { path.removeLast() }
                    } label: {
                        Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Back")
                    .background(.regularMaterial, in: Circle())
                }
                Spacer()
                if let menu = pageMenu(root: root, route: route) {
                    PhonePageActionsMenu(menu: menu)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            content()
        }
        .toolbar(.hidden, for: .navigationBar)
        .background(Color(uiColor: .systemBackground))
    }

    private func pageMenu(root: Bool, route: PhoneRoute?) -> PhonePageMenu? {
        if root {
            switch tab {
            case .home:
                return .home(openSettings: { path.append(.settings) })
            case .tasks:
                let tagActions = [PhonePageMenuAction(
                    id: "all-tags", title: "All tags", systemImage: "tag",
                    isSelected: selectedTag == nil, perform: { selectedTag = nil }
                )] + taskTags.map { tag in
                    PhonePageMenuAction(id: "tag-\(tag)", title: "#\(tag)", systemImage: "number",
                                        isSelected: selectedTag == tag, perform: { selectedTag = tag })
                }
                return PhonePageMenu(pageTitle: "Tasks", actions: tagActions)
            case .calendar:
                return PhonePageMenu(pageTitle: "Calendar", actions: [
                    PhonePageMenuAction(id: "settings", title: "Settings", systemImage: "gearshape",
                                        perform: { path.append(.settings) })
                ])
            }
        }
        switch route {
        case .allNotes:
            return PhonePageMenu(pageTitle: "All notes", actions: [
                PhonePageMenuAction(id: "refresh", title: "Refresh", systemImage: "arrow.clockwise",
                                    perform: { state.refresh() })
            ])
        case .canvases:
            return PhonePageMenu(pageTitle: "Canvases", actions: [
                PhonePageMenuAction(id: "refresh", title: "Refresh", systemImage: "arrow.clockwise",
                                    perform: { state.refresh() })
            ])
        case .note, .task, .canvas, .settings, .none:
            return nil
        }
    }

    @ViewBuilder private var rootContent: some View {
        if !state.loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch tab {
            case .home: home
            case .tasks: tasks
            case .calendar:
                PhoneCalendarPage(tasks: state.tasks, syntheticEventsEnabled: syntheticCalendar) { taskID in
                    path.append(.task(taskID))
                }
            }
        }
    }

    @ViewBuilder private func destination(_ route: PhoneRoute) -> some View {
        switch route {
        case let .allNotes(tag): notesList(tag: tag)
        case let .note(id): PhoneNotePage(state: state, noteID: id)
        case let .task(id): PhoneTaskPage(state: state, taskID: id) { noteID in
            path.append(.note(noteID))
        }
        case .canvases: canvasesList
        case let .canvas(id): PhoneDrawEditor(state: state, canvasID: id) {
            if !path.isEmpty { path.removeLast() }
        }
        case .settings: PhoneSettingsPage()
        }
    }

    private var dock: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(PhoneTab.allCases) { option in
                    Button {
                        if !path.isEmpty { path.removeAll() }
                        withAnimation(.easeInOut(duration: 0.22)) { tab = option }
                    } label: {
                        Image(systemName: tab == option ? option.selectedSymbol : option.symbol)
                            .font(.system(size: 22))
                            .frame(width: 48, height: 44)
                            .foregroundStyle(tab == option ? Color.accentColor : Color.primary)
                            .background {
                                if tab == option { Capsule().fill(Color.accentColor.opacity(0.11)) }
                            }
                    }
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(tab == option ? .isSelected : [])
                }
            }
            .padding(4)
            .background(.regularMaterial, in: Capsule())
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                if let captureConfirmation {
                    Label {
                        Text(captureConfirmation).font(.system(size: 15, weight: .semibold))
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("phone-capture-confirmation")
                } else {
                    Button { searchPresented = true } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 21))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Search")
                    Button { capturePresented = true } label: {
                        Image(systemName: "plus").font(.system(size: 24, weight: .regular))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Create")
                }
            }
            .padding(4)
            .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 5)
        // Keep scroll content from ghosting through the hit targets at the
        // bottom edge; the capsules themselves retain their native material.
        .background(Color(uiColor: .systemBackground))
    }

    private func pageTitle(_ text: String) -> some View {
        Text(text).font(.system(size: pageTitleSize, weight: .bold))
            .tracking(-1.0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 13)
            .padding(.bottom, 10)
            .accessibilityAddTraits(.isHeader)
    }

    private var home: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                pageTitle("Home")
                Button { searchPresented = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                        Text("Search")
                        Spacer()
                    }
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(height: 44)
                    .padding(.horizontal, 14)
                    .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                if !state.notes.isEmpty || !state.tasks.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(Array(state.notes.prefix(3))) { note in
                                Button { path.append(.note(note.id)) } label: {
                                    VStack(alignment: .leading, spacing: 9) {
                                        Text(note.title.isEmpty ? "Untitled note" : note.title)
                                            .font(.system(size: 16, weight: .semibold)).lineLimit(2)
                                        Divider()
                                        Text(note.body.isEmpty ? " " : note.body)
                                            .font(.system(size: 13)).foregroundStyle(.secondary)
                                            .lineLimit(7).frame(maxWidth: .infinity, alignment: .leading)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(14)
                                    .frame(width: 150, height: 185, alignment: .topLeading)
                                    .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.quaternary))
                                }
                                .foregroundStyle(.primary)
                            }
                            Button {
                                path.removeAll()
                                tab = .tasks
                            } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Today").font(.system(size: 16, weight: .semibold))
                                    Divider()
                                    ForEach(Array(state.tasks.filter { $0.listedStatus != .done }.prefix(3))) { task in
                                        Label(task.title, systemImage: "circle")
                                            .font(.system(size: 12)).lineLimit(2)
                                    }
                                    Spacer()
                                }
                                .padding(14)
                                .frame(width: 150, height: 185, alignment: .topLeading)
                                .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(.quaternary))
                            }
                            .foregroundStyle(.primary)
                        }.padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 18)
                }
                homeLink("All notes", symbol: "note.text") { path.append(.allNotes(tag: nil)) }
                homeLink("Canvases", symbol: "scribble.variable") { path.append(.canvases) }

                sectionHeading("Pinned", icon: "pin", count: state.notes.filter { $0.pinnedAt != nil }.count,
                               key: "home-pinned")
                if !collapsed.contains("home-pinned") {
                    let pinned = state.notes.filter { $0.pinnedAt != nil }
                    if pinned.isEmpty { emptySection("No pinned notes") }
                    ForEach(pinned) { note in
                        noteRow(note) { path.append(.note(note.id)) }
                    }
                }
                sectionHeading("Tags", icon: "number", count: noteTags.count, key: "home-tags")
                if !collapsed.contains("home-tags") {
                    if noteTags.isEmpty { emptySection("No tags yet") }
                    ForEach(noteTags, id: \.self) { tag in
                        Button {
                            if expandedTags.contains(tag) { expandedTags.remove(tag) }
                            else { expandedTags.insert(tag) }
                        } label: {
                            HStack(spacing: 13) {
                                Text("#").font(.system(size: 22, weight: .medium)).foregroundStyle(.tint)
                                    .frame(width: 24)
                                Text(tag).font(.body).foregroundStyle(.primary)
                                Spacer()
                                Text(state.notes.filter { $0.tags.contains(tag) }.count, format: .number)
                                    .foregroundStyle(.secondary)
                                Image(systemName: expandedTags.contains(tag) ? "chevron.up" : "chevron.down")
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 20)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("#\(tag)")
                        .accessibilityValue(expandedTags.contains(tag) ? "Expanded" : "Collapsed")
                        if expandedTags.contains(tag) {
                            ForEach(state.notes.filter { $0.tags.contains(tag) }) { note in
                                noteRow(note) { path.append(.note(note.id)) }.padding(.leading, 20)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 110)
        }
    }

    private func homeLink(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol).font(.system(size: 21)).foregroundStyle(.secondary).frame(width: 24)
                Text(title).font(.body).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var noteTags: [String] {
        Array(Set(state.notes.flatMap(\.tags))).sorted()
    }
    private var taskTags: [String] {
        Array(Set(state.tasks.flatMap(\.tags))).sorted()
    }

    private var tasks: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                pageTitle("Tasks")
                HStack(spacing: 8) {
                    ForEach(PhoneTasksTab.allCases) { option in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { tasksTab = option }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: option.symbol)
                                if tasksTab == option { Text(option.title) }
                            }
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(tasksTab == option ? Color.accentColor : Color.secondary)
                            .frame(minWidth: 50, minHeight: 44)
                            .padding(.horizontal, tasksTab == option ? 12 : 2)
                            .background(tasksTab == option ? Color.accentColor.opacity(0.12) : Color(uiColor: .secondarySystemFill),
                                        in: Capsule())
                        }.accessibilityLabel(option.title).accessibilityAddTraits(tasksTab == option ? .isSelected : [])
                    }
                    if let selectedTag {
                        Button { self.selectedTag = nil } label: {
                            HStack(spacing: 8) {
                                Text("#" + selectedTag).lineLimit(1)
                                Image(systemName: "xmark").font(.caption)
                            }.foregroundStyle(.tint)
                                .padding(.horizontal, 12).frame(height: 44)
                                .background(Color.accentColor.opacity(0.1), in: Capsule())
                        }.accessibilityLabel("Remove #\(selectedTag) filter")
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
                let groups = taskGroups
                if groups.isEmpty {
                    ContentUnavailableView(tasksTab == .done ? "Nothing completed" : "No tasks",
                                           systemImage: "checkmark.circle",
                                           description: Text(selectedTag == nil ? "Create a task with +." : "No tasks have this tag."))
                        .frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    ForEach(groups) { group in
                        sectionHeading(group.title, icon: group.symbol, count: group.rows.count, key: group.key)
                        if !collapsed.contains(group.key) {
                            ForEach(group.rows) { task in
                                taskRow(task)
                            }
                        }
                    }
                }
            }.padding(.bottom, 110)
        }
    }

    private struct TaskGroup: Identifiable {
        let key: String, title: String, symbol: String, rows: [PhoneLibrary.TaskRow]
        var id: String { key }
    }

    private var taskGroups: [TaskGroup] {
        let today = DueDay(date: Date(), calendar: .autoupdatingCurrent)
        let next = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: Date())
            .map { DueDay(date: $0, calendar: .autoupdatingCurrent) } ?? today
        let rows = state.tasks.filter { item in
            item.parentID == nil && (selectedTag == nil || item.tags.contains(selectedTag!)) &&
            (tasksTab == .done ? item.listedStatus == .done :
             tasksTab == .later ? item.listedStatus == .backlog :
             item.listedStatus != .done && item.listedStatus != .backlog)
        }
        if tasksTab != .now {
            let title = tasksTab == .done ? "This week" : "Later"
            return rows.isEmpty ? [] : [TaskGroup(key: "tasks-\(tasksTab.rawValue)", title: title,
                                                 symbol: tasksTab.symbol, rows: rows)]
        }
        var result: [TaskGroup] = []
        func add(_ name: String, _ key: String, _ symbol: String, _ filter: (PhoneLibrary.TaskRow) -> Bool) {
            let items = rows.filter(filter)
            if !items.isEmpty { result.append(.init(key: key, title: name, symbol: symbol, rows: items)) }
        }
        add("Overdue", "overdue", "exclamationmark.circle") { $0.dueDay.map { $0 < today } ?? false }
        add("Today", "today", "sun.max") { $0.dueDay == today }
        add("Tomorrow", "tomorrow", "sunrise") { $0.dueDay == next }
        let upcoming = Dictionary(grouping: rows.filter { ($0.dueDay ?? today) > next }, by: \.dueDay)
        for day in upcoming.keys.compactMap({ $0 }).sorted() {
            let label = day.startDate(in: .autoupdatingCurrent)?.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)) ?? day.rawValue
            if let items = upcoming[day] { result.append(.init(key: day.rawValue, title: label, symbol: "calendar", rows: items)) }
        }
        add("No date", "no-date", "tray") { $0.dueDay == nil }
        return result
    }

    private func taskRow(_ row: PhoneLibrary.TaskRow) -> some View {
        HStack(spacing: 12) {
            Button {
                let destination: TaskStatus = row.listedStatus == .done ? .todo : .done
                state.change { _ = try state.library.updateTask(
                    id: row.id, patch: .init(title: nil, priority: nil, status: destination)) }
            } label: {
                Image(systemName: row.listedStatus == .done ? "checkmark.circle.fill" :
                        row.listedStatus == .backlog ? "circle.dashed" :
                        row.status == .inProgress ? "circle.lefthalf.filled" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle((row.dueDay.map { $0 < DueDay(date: Date(), calendar: .autoupdatingCurrent) } ?? false)
                                     ? Color.red : Color.secondary)
                    .frame(width: 28, height: 44)
            }.accessibilityLabel(row.listedStatus == .done ? "Mark not done" : "Mark done")
            Button { path.append(.task(row.id)) } label: {
                HStack(spacing: 6) {
                    Text(row.title).font(.body).lineLimit(1)
                        .foregroundStyle(row.listedStatus == .done ? Color.secondary : Color.primary)
                    if row.priority == .high {
                        Text("!!").font(.system(size: 14, weight: .bold)).foregroundStyle(.orange)
                    }
                    Spacer(minLength: 3)
                    if let due = row.dueDay {
                        chip(due.startDate(in: .autoupdatingCurrent)?.formatted(.dateTime.day().month(.abbreviated)) ?? due.rawValue,
                             overdue: due < DueDay(date: Date(), calendar: .autoupdatingCurrent))
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(row.title)
            .accessibilityHint("Open task")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .contextMenu {
            Button("Edit", systemImage: "pencil") { path.append(.task(row.id)) }
            Button("Move to Later", systemImage: "clock") {
                state.change { _ = try state.library.updateTask(id: row.id, patch: .init(title: nil, priority: nil, status: .backlog)) }
            }
            Button(row.listedStatus == .done ? "Move to Now" : "Mark Done", systemImage: "checkmark") {
                state.change { _ = try state.library.updateTask(id: row.id, patch: .init(title: nil, priority: nil,
                                                                                         status: row.listedStatus == .done ? .todo : .done)) }
            }
        }
    }

    private func chip(_ text: String, overdue: Bool = false) -> some View {
        Text(text).font(.system(size: 14, weight: .medium)).lineLimit(1)
            .foregroundStyle(overdue ? Color.red : Color.accentColor)
            .padding(.horizontal, 8).frame(height: 26)
            .background(overdue ? Color.red.opacity(0.1) : Color.accentColor.opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 7))
    }

    private func sectionHeading(_ title: String, icon: String, count: Int, key: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 19)).foregroundStyle(.secondary).frame(width: 23)
                Text(title).font(.system(size: 17, weight: .semibold))
                Spacer()
                if collapsed.contains(key) { Text("\(count)").foregroundStyle(.secondary) }
                Image(systemName: collapsed.contains(key) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 16)).foregroundStyle(.tertiary).frame(width: 32)
            }
            .padding(.leading, 20).padding(.trailing, 12)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) items")
        .accessibilityValue(collapsed.contains(key) ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(.isHeader)
    }

    private func emptySection(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .padding(.horizontal, 22).padding(.vertical, 12)
    }

    private func noteRow(_ row: PhoneLibrary.NoteRow, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "note.text").font(.system(size: 20))
                    .foregroundStyle(.secondary).frame(width: 28)
                Text(row.title.isEmpty ? "Untitled note" : row.title).font(.body).lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                chip(row.updatedAt.formatted(.dateTime.hour().minute()))
            }
            .padding(.horizontal, 20).frame(minHeight: 44)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func notesList(tag: String?) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                pageTitle("All notes").accessibilityIdentifier("phone-all-notes-title")
                if let tag {
                    Button { path.removeLast() } label: {
                        Label("#" + tag, systemImage: "xmark.circle.fill")
                            .padding(.horizontal, 14).frame(height: 34)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }.padding(.horizontal, 18)
                }
                let filtered = state.notes.filter { tag == nil || $0.tags.contains(tag!) }
                let today = Calendar.autoupdatingCurrent.startOfDay(for: Date())
                let weekAgo = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -7, to: today) ?? today
                let groups: [(String, String, [PhoneLibrary.NoteRow])] = [
                    ("Pinned", "pin", filtered.filter { $0.pinnedAt != nil }),
                    ("Today", "sun.max", filtered.filter { $0.pinnedAt == nil && $0.updatedAt >= today }),
                    ("This week", "calendar", filtered.filter { $0.pinnedAt == nil && $0.updatedAt < today && $0.updatedAt >= weekAgo }),
                    ("Earlier", "tray", filtered.filter { $0.pinnedAt == nil && $0.updatedAt < weekAgo })
                ]
                if filtered.isEmpty { ContentUnavailableView("No notes", systemImage: "note.text").padding(.top, 40) }
                ForEach(groups.indices, id: \.self) { i in
                    let group = groups[i]
                    if !group.2.isEmpty {
                        sectionHeading(group.0, icon: group.1, count: group.2.count, key: "notes-" + group.0)
                        if !collapsed.contains("notes-" + group.0) {
                            ForEach(group.2) { note in noteRow(note) { path.append(.note(note.id)) } }
                        }
                    }
                }
            }
            .padding(.bottom, 110)
        }
    }

    private var canvasesList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                pageTitle("Canvases").accessibilityIdentifier("phone-canvases-title")
                Button {
                    let canvas = state.draw.create()
                    state.refresh()
                    path.append(.canvas(canvas.id))
                } label: {
                    Label("New canvas", systemImage: "plus")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .accessibilityIdentifier("phone-create-canvas")
                if state.canvases.isEmpty {
                    ContentUnavailableView("No canvases", systemImage: "scribble.variable")
                        .frame(maxWidth: .infinity).padding(.top, 35)
                } else {
                    ForEach(state.canvases, id: \.id) { canvas in
                        Button { path.append(.canvas(canvas.id)) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "scribble.variable").font(.system(size: 20))
                                    .foregroundStyle(.secondary).frame(width: 28)
                                Text(canvas.name).foregroundStyle(.primary)
                                Spacer()
                                chip(canvas.updatedAt.formatted(.dateTime.day().month(.abbreviated)))
                            }.padding(.horizontal, 20).frame(minHeight: 44)
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(.bottom, 110)
        }
    }
}

/// The shell owns this value so tapping outside a half-height capture card
/// preserves the draft for the next presentation. Only a successful create
/// resets it; a rejected save never throws the entered writing away.
struct PhoneCaptureDraft {
    enum Kind: String, CaseIterable { case task = "Task", note = "Note" }
    var kind: Kind = .task
    var title = ""
    var bodyText = ""
    var priority: TaskPriority = .none
    var dueEnabled = false
    var dueDate = Date()
    var pinned = false
    var later = false
    var tags = ""

    var normalizedTags: [String] {
        AtticTag.normalizedSet(tags.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init))
    }
}

private struct PhoneCaptureSheet: View {
    @ObservedObject var state: PhoneAppState
    @Binding var draft: PhoneCaptureDraft
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool
    @State private var saveError: String?
    @State private var priorityExpanded = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("Create", selection: $draft.kind) {
                    ForEach(PhoneCaptureDraft.Kind.allCases, id: \.self) { kind in Text(kind.rawValue).tag(kind) }
                }.pickerStyle(.segmented)
                TextField("Title", text: $draft.title).focused($titleFocused)
                    .accessibilityIdentifier("phone-capture-title")
                if draft.kind == .note {
                    TextEditor(text: $draft.bodyText).frame(minHeight: 105)
                    Toggle("Pin", isOn: $draft.pinned)
                } else {
                    if priorityExpanded {
                        HStack(spacing: 3) {
                            ForEach(TaskPriority.allCases) { level in
                                Button {
                                    draft.priority = level
                                    withAnimation(.easeInOut(duration: 0.16)) { priorityExpanded = false }
                                } label: {
                                    Text(level == .high ? "!! High" : level.title)
                                        .font(.system(size: 14, weight: .medium))
                                        .frame(maxWidth: .infinity, minHeight: 36)
                                        .foregroundStyle(draft.priority == level ? Color.primary : Color.secondary)
                                        .background(draft.priority == level ? Color(uiColor: .secondarySystemBackground) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 8))
                                }
                                .accessibilityIdentifier("phone-priority-\(level.rawValue)")
                                .accessibilityAddTraits(draft.priority == level ? .isSelected : [])
                            }
                        }
                        .padding(3)
                        .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("phone-priority-expanded")
                    } else {
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) { priorityExpanded = true }
                        } label: {
                            HStack {
                                Text("Priority")
                                Spacer()
                                Text(draft.priority == .high ? "!! High" : draft.priority.title)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.down").font(.caption).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("phone-priority-expand")
                        Toggle("Later", isOn: $draft.later)
                            .onChange(of: draft.later) { _, later in
                                if later { draft.dueEnabled = false }
                            }
                        Toggle("Set date", isOn: $draft.dueEnabled)
                            .onChange(of: draft.dueEnabled) { _, enabled in
                                if enabled { draft.later = false }
                            }
                        if draft.dueEnabled { DatePicker("Due", selection: $draft.dueDate, displayedComponents: .date) }
                    }
                }
                if !priorityExpanded {
                    TextField("Tags", text: $draft.tags)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("New \(draft.kind.rawValue.lowercased())")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") {
                        let ok: Bool
                        switch draft.kind {
                        case .task:
                            let day = draft.dueEnabled ? DueDay(date: draft.dueDate, calendar: .autoupdatingCurrent) : nil
                            ok = state.createTask(draft.title, priority: draft.priority, dueDay: day,
                                                  status: draft.later ? .backlog : .todo, tags: draft.normalizedTags)
                        case .note:
                            ok = state.createNote(draft.title, body: draft.bodyText, pinned: draft.pinned,
                                                  tags: draft.normalizedTags)
                        }
                        if ok {
                            titleFocused = false
                            onCreated()
                        } else {
                            // An alert attached to the obscured parent cannot
                            // reliably surface over this sheet.
                            saveError = state.errorMessage ?? "The operation could not be completed."
                            state.errorMessage = nil
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                              (draft.kind == .task || draft.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .accessibilityIdentifier("phone-capture-create")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { titleFocused = true }
        .alert("Could not save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "The operation could not be completed.")
        }
    }
}
