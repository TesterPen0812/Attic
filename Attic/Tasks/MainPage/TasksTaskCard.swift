import AppKit
import SwiftUI

// The task opened in place (council D2, pick 3A): the row grows into a card
// in the list (`states-d1.png` panel 4), and ⌘↩ grows the card into the
// list area (panel 5). Every field saves as it changes, through the page
// model's producers; Esc closes and keeps; ⌘Z undoes.

/// Values from `final/council-lib.js` (`cardHTML`, `itemBody`).
enum TasksCardMetrics {
    static let radius: CGFloat = 12
    static let outerHorizontal: CGFloat = 8
    static let outerTop: CGFloat = 2
    static let outerBottom: CGFloat = 4
    static let insetTop: CGFloat = 7
    static let insetLeading: CGFloat = 38
    static let insetTrailing: CGFloat = 10
    static let insetBottom: CGFloat = 9
    static let ringLeading: CGFloat = 9
    static let ring: CGFloat = 18
    static let collapse: CGFloat = 22
    static let titleSize: CGFloat = 13
    static let writingSize: CGFloat = 12.5
    static let chipHeight: CGFloat = 22
    static let chipGap: CGFloat = 4
    static let subtaskRow: CGFloat = 24
    static let subtaskRing: CGFloat = 14
    static let footerSize: CGFloat = 11
    // Full (itemBody): 16 pt sides, a 16 pt semibold title, 26 pt subtasks.
    static let fullSide: CGFloat = 16
    static let fullTitleSize: CGFloat = 16
    static let fullSubtaskRow: CGFloat = 26
    static let fullSubtaskRing: CGFloat = 15
    static let fullIndent: CGFloat = 28
    static let photo = CGSize(width: 84, height: 58)
    static let cardPhoto = CGSize(width: 56, height: 40)
}

/// The glass inks this card uses (FINAL §2 clear fix 5; Build A owns the
/// rows' own copy).
enum TasksCardInk {
    static let orange = dynamic(light: (0xA3, 0x3A, 0x00), dark: (0xFF, 0x9F, 0x0A))
    static let red = dynamic(light: (0xA3, 0x16, 0x0E), dark: (0xFF, 0x69, 0x61))
    static let accent = dynamic(light: (0x09, 0x4C, 0xA6), dark: (0x64, 0xA8, 0xFF))

    private static func dynamic(light: (Int, Int, Int), dark: (Int, Int, Int)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
        })
    }
}

struct TasksTaskCard: View {
    let taskID: UUID
    let isFull: Bool
    let model: TasksPageModel
    @ObservedObject var state: TasksMainPageState
    /// Re-read when the store changes (the card shows live fields).
    let revision: UInt64
    /// "Now", "Later" or "Done": full's back button.
    let listTitle: String

    @State private var title = ""
    @State private var writing = ""
    @State private var newSubtask = ""
    @State private var addingSubtask = false
    @State private var newTag = ""
    @State private var addingTag = false
    @State private var link = ""
    @State private var editingLink = false
    @State private var choosingDate = false
    @State private var pickedDate = Date()
    @State private var photos: [RemindersReplicaPhoto] = []
    @FocusState private var focus: Field?
    @Environment(\.colorScheme) private var colorScheme

    private enum Field: Hashable { case title, writing, subtask, tag, link }
    private typealias M = TasksCardMetrics

    private var task: TaskItem? { model.store.listedTask(withID: taskID) ?? model.store.task(withID: taskID) }

    var body: some View {
        Group {
            if let task {
                if isFull { full(task) } else { card(task) }
            }
        }
        .background(RemindersReplicaEscapeCatcher(onEscape: escape))
        .onAppear(perform: load)
        .onChange(of: revision) { _, _ in refreshFromStore() }
        .onChange(of: state.cardWriting) { _, snapshot in
            if focus != .writing { writing = snapshot?.text ?? "" }
        }
        .onChange(of: focus) { old, _ in commit(old) }
        .onDisappear { commit(.title); commit(.writing) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isFull ? "tasks-card-full" : "tasks-card")
    }

    // MARK: Card (in the list)

    private func card(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            titleField(size: M.titleSize, weight: .regular)
                .padding(.trailing, M.collapse + 4)
                .padding(.bottom, 5)
            writingField(size: M.writingSize, lineSpacing: 17 - 15.2, ink: .secondary)
                .padding(.bottom, 8)
            chips(task)
            if !photos.isEmpty || model.canAddReplicaPhoto { photoStrip(size: M.cardPhoto).padding(.top, 6) }
            subtasks(row: M.subtaskRow, ring: M.subtaskRing, size: M.writingSize)
                .padding(.top, 6)
            footer
                .padding(.top, 6)
        }
        .padding(EdgeInsets(top: M.insetTop, leading: M.insetLeading, bottom: M.insetBottom, trailing: M.insetTrailing))
        .overlay(alignment: .topLeading) {
            ring(task, size: M.ring).padding(.leading, M.ringLeading).padding(.top, M.insetTop)
        }
        .overlay(alignment: .topTrailing) { collapseButton.padding(.top, 5).padding(.trailing, 8) }
        .background(
            RoundedRectangle(cornerRadius: M.radius, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.42))
                .overlay(RoundedRectangle(cornerRadius: M.radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        )
        .padding(EdgeInsets(top: M.outerTop, leading: M.outerHorizontal, bottom: M.outerBottom, trailing: M.outerHorizontal))
    }

    private var collapseButton: some View {
        Button { model.closeCard() } label: {
            Image(systemName: "chevron.up")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: M.collapse, height: M.collapse)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(String(localized: "Close (Esc)"))
        .accessibilityLabel(String(localized: "Close"))
    }

    private var footer: some View {
        HStack {
            Button { model.openCardFull() } label: {
                Text("Open full ⌘↩").font(.system(size: M.footerSize, weight: .medium)).foregroundStyle(TasksCardInk.accent)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier("tasks-card-open-full")
            Spacer()
            Text("Saved · Esc closes").font(.system(size: M.footerSize)).foregroundStyle(.tertiary)
        }
    }

    // MARK: Full (the list area)

    private func full(_ task: TaskItem) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button { model.shrinkCard() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                            Text(listTitle).font(.system(size: 12.5, weight: .medium))
                        }
                        .foregroundStyle(TasksCardInk.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tasks-card-shrink")
                    Spacer()
                    Text("Saved · Esc returns").font(.system(size: M.footerSize)).foregroundStyle(.tertiary)
                }
                .frame(height: 22)
                .padding(.bottom, 8)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    ring(task, size: M.ring).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                    titleField(size: M.fullTitleSize, weight: .semibold)
                }
                .padding(.bottom, 9)
                chips(task).padding(.leading, M.fullIndent)
                let all = model.cardSubtasks()
                HStack(spacing: 4) {
                    Text("Subtasks").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    if !all.isEmpty {
                        Text("\(all.filter { $0.status == .done }.count)/\(all.count)")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 12).padding(.bottom, 2).padding(.leading, M.fullIndent)
                subtasks(row: M.fullSubtaskRow, ring: M.fullSubtaskRing, size: 13).padding(.leading, M.fullIndent)
                Divider().padding(.vertical, 10).padding(.leading, M.fullIndent)
                writingField(size: 13, lineSpacing: 19 - 15.8, ink: .primary).padding(.leading, M.fullIndent)
                photoStrip(size: M.photo).padding(.top, 10).padding(.leading, M.fullIndent)
            }
            .padding(.horizontal, M.fullSide)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.automatic)
    }

    // MARK: Fields

    private func titleField(size: CGFloat, weight: Font.Weight) -> some View {
        TextField(String(localized: "Title"), text: $title, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: size, weight: weight))
            .focused($focus, equals: .title)
            .onSubmit { commit(.title) }
            .accessibilityIdentifier("tasks-card-title")
    }

    @ViewBuilder
    private func writingField(size: CGFloat, lineSpacing: CGFloat, ink: HierarchicalShapeStyle) -> some View {
        if let snapshot = state.cardWriting, !snapshot.isPlain {
            // Formatting, links, checkboxes or objects: shown here, edited
            // on the item's page so nothing is flattened.
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: size)).foregroundStyle(ink).lineSpacing(lineSpacing)
                    .lineLimit(isFull ? nil : 4)
                if model.services.openTaskNote != nil {
                    Button { model.services.openTaskNote?(taskID) } label: {
                        Text("Edit writing on its page").font(.system(size: M.footerSize, weight: .medium)).foregroundStyle(TasksCardInk.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if model.services.writeWriting != nil {
            TextField(String(localized: "Add writing"), text: $writing, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: size)).foregroundStyle(ink).lineSpacing(lineSpacing)
                .lineLimit(isFull ? nil : 6)
                .focused($focus, equals: .writing)
                .disabled(state.cardWriting == nil)
                .accessibilityIdentifier("tasks-card-writing")
        }
    }

    // MARK: Chips (match the add bar's)

    private func chips(_ task: TaskItem) -> some View {
        RemindersReplicaWrap(spacing: M.chipGap) {
            dateChip(task)
            if task.status != .done { listChip(task) }
            ForEach(task.tags, id: \.self) { tag in tagChip(tag, in: task) }
            addTagChip(task)
            priorityChip(task)
            flagChip(task)
            linkChip(task)
        }
    }

    private func chip<Label: View>(strong: Bool = true, @ViewBuilder _ label: () -> Label) -> some View {
        HStack(spacing: 4, content: label)
            .font(.system(size: 12))
            .foregroundStyle(strong ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, 8)
            .frame(height: M.chipHeight)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .contentShape(Capsule())
    }

    private func dateChip(_ task: TaskItem) -> some View {
        let choices = model.dateChoices
        let overdue = task.dueDay.map { $0 < choices.today } ?? false
        return Menu {
            ForEach(choices.quick) { quick in
                Button(quick.menuTitle) { model.setCardDue(quick.day) }
            }
            Button(String(localized: "Choose Date…")) {
                pickedDate = task.dueDay?.startDate(in: .autoupdatingCurrent) ?? Date()
                choosingDate = true
            }
            if task.dueDay != nil {
                Divider()
                Button(String(localized: "No Date")) { model.setCardDue(nil) }
            }
        } label: {
            chip(strong: task.dueDay != nil) {
                Image(systemName: "calendar").font(.system(size: 11))
                    .foregroundStyle(overdue ? AnyShapeStyle(TasksCardInk.red) : AnyShapeStyle(.secondary))
                Text(task.dueDay.map(choices.detail(for:)) ?? String(localized: "Date"))
                    .fontWeight(overdue ? .semibold : .regular)
                    .foregroundStyle(overdue ? AnyShapeStyle(TasksCardInk.red) : AnyShapeStyle(.primary))
            }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .popover(isPresented: $choosingDate) {
            DatePicker("", selection: $pickedDate, displayedComponents: .date)
                .datePickerStyle(.graphical).labelsHidden().padding(10)
                .onChange(of: pickedDate) { _, date in
                    model.setCardDue(DueDay(date: date, calendar: .autoupdatingCurrent))
                }
        }
        .accessibilityLabel(String(localized: "Date"))
    }

    private func listChip(_ task: TaskItem) -> some View {
        let inLater = task.status == .backlog
        return Menu {
            Button(TasksTab.now.title) { model.setCardList(.now) }.disabled(!inLater)
            Button(TasksTab.backlog.title) { model.setCardList(.backlog) }.disabled(inLater)
        } label: {
            chip {
                Image(systemName: "checklist").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(inLater ? TasksTab.backlog.title : TasksTab.now.title)
            }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(String(localized: "List"))
    }

    private func tagChip(_ tag: String, in task: TaskItem) -> some View {
        Menu {
            Button(String(localized: "Remove #\(tag)")) { model.setCardTags(task.tags.filter { $0 != tag }) }
        } label: {
            chip { (Text("#").foregroundStyle(.tertiary) + Text(tag)) }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    @ViewBuilder
    private func addTagChip(_ task: TaskItem) -> some View {
        if addingTag {
            TextField(String(localized: "tag"), text: $newTag)
                .textFieldStyle(.plain).font(.system(size: 12))
                .frame(width: 80, height: M.chipHeight)
                .padding(.horizontal, 8)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .focused($focus, equals: .tag)
                .onSubmit { commit(.tag) }
        } else {
            Button { addingTag = true; focus = .tag } label: {
                chip(strong: false) { Text("#").fontWeight(.semibold) }
            }
            .buttonStyle(.plain)
            .help(String(localized: "Add a tag"))
            .accessibilityLabel(String(localized: "Add Tag"))
        }
    }

    private func priorityChip(_ task: TaskItem) -> some View {
        let marks = ["", "!", "!!", "!!!"]
        let rank = [TaskPriority.none, .low, .medium, .high].firstIndex(of: task.priority) ?? 0
        return Menu {
            ForEach([TaskPriority.none, .low, .medium, .high], id: \.self) { priority in
                Button(priority == .none ? String(localized: "No Priority") : priority.title) { model.setCardPriority(priority) }
            }
        } label: {
            chip(strong: rank > 0) {
                if rank > 0 {
                    Text(marks[rank]).fontWeight(.bold).foregroundStyle(TasksCardInk.orange)
                    Text(task.priority.title)
                } else {
                    Text("!").fontWeight(.bold)
                }
            }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(String(localized: "Priority"))
    }

    private func flagChip(_ task: TaskItem) -> some View {
        Button { model.setCardFlag(!task.isFlagged) } label: {
            chip(strong: task.isFlagged) {
                Image(systemName: task.isFlagged ? "flag.fill" : "flag").font(.system(size: 10))
                    .foregroundStyle(task.isFlagged ? AnyShapeStyle(TasksCardInk.orange) : AnyShapeStyle(.tertiary))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(task.isFlagged ? String(localized: "Unflag") : String(localized: "Flag"))
    }

    @ViewBuilder
    private func linkChip(_ task: TaskItem) -> some View {
        if editingLink {
            TextField(String(localized: "Link"), text: $link)
                .textFieldStyle(.plain).font(.system(size: 12))
                .frame(minWidth: 120, maxWidth: 200, minHeight: M.chipHeight)
                .padding(.horizontal, 8)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .focused($focus, equals: .link)
                .onSubmit { commit(.link) }
        } else {
            Button { link = task.url ?? ""; editingLink = true; focus = .link } label: {
                chip(strong: task.url != nil) {
                    Image(systemName: "link").font(.system(size: 10)).foregroundStyle(.secondary)
                    if let url = task.url { Text(URL(string: url)?.host() ?? url).lineLimit(1) }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Link"))
        }
    }

    // MARK: Subtasks

    private func subtasks(row: CGFloat, ring: CGFloat, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.cardSubtasks(), id: \.id) { subtask in
                HStack(spacing: 9) {
                    Button { model.toggleSubtask(subtask.id) } label: {
                        subtaskRing(done: subtask.status == .done, size: ring)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(subtask.status == .done ? String(localized: "Mark not done") : String(localized: "Complete"))
                    Text(subtask.title).font(.system(size: size))
                        .foregroundStyle(subtask.status == .done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .strikethrough(subtask.status == .done)
                        .lineLimit(1)
                }
                .frame(height: row)
            }
            HStack(spacing: 9) {
                Image(systemName: "plus.circle.dashed").font(.system(size: ring - 1)).foregroundStyle(.tertiary)
                    .frame(width: ring, height: ring)
                if addingSubtask {
                    TextField(String(localized: "Add subtask"), text: $newSubtask)
                        .textFieldStyle(.plain).font(.system(size: size))
                        .focused($focus, equals: .subtask)
                        .onSubmit(addSubtask)
                        .accessibilityIdentifier("tasks-card-new-subtask")
                } else {
                    Button { addingSubtask = true; focus = .subtask } label: {
                        Text("Add subtask").font(.system(size: size)).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tasks-card-add-subtask")
                }
            }
            .frame(height: row)
        }
    }

    private func subtaskRing(done: Bool, size: CGFloat) -> some View {
        ZStack {
            if done {
                Circle().fill(TasksCardInk.accent)
                Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
            } else {
                Circle().strokeBorder(Color.primary.opacity(0.42), lineWidth: 1.3)
            }
        }
        .frame(width: size, height: size)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }

    private func ring(_ task: TaskItem, size: CGFloat) -> some View {
        Button {
            if task.status == .done { model.reopen(task.id) } else { model.complete(task.id) }
        } label: {
            ZStack {
                if task.status == .done {
                    Circle().fill(TasksCardInk.accent)
                    Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
                } else {
                    Circle().strokeBorder(Color.primary.opacity(0.42), lineWidth: 1.5)
                    if task.status == .inProgress { Circle().fill(Color.primary.opacity(0.42)).frame(width: 6, height: 6) }
                }
            }
            .frame(width: size, height: size)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-3)
        .accessibilityLabel(task.status == .done ? String(localized: "Mark not done") : String(localized: "Complete"))
    }

    // MARK: Photos

    @ViewBuilder
    private func photoStrip(size: CGSize) -> some View {
        if !photos.isEmpty || model.canAddReplicaPhoto {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(photos) { photo in
                        TasksCardThumbnail(photo: photo, size: size, model: model)
                    }
                    if model.canAddReplicaPhoto {
                        Button { model.addReplicaPhoto(to: taskID) } label: {
                            Image(systemName: "photo.badge.plus").font(.system(size: 13)).foregroundStyle(.tertiary)
                                .frame(width: size.height, height: size.height)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Add Photo"))
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    // MARK: Saving as it goes

    private func load() {
        guard let task else { return }
        title = task.title
        writing = state.cardWriting?.text ?? ""
        photos = model.replicaPhotos(for: taskID)
        if isFull, focus == nil { focus = .writing }
    }

    private func refreshFromStore() {
        guard let task else { return }
        if focus != .title { title = task.title }
        photos = model.replicaPhotos(for: taskID)
    }

    private func commit(_ field: Field?) {
        switch field {
        case .title:
            guard let task, title != task.title else { return }
            if !model.commitCardTitle(title).isApplied { title = task.title }
        case .writing:
            let text = writing, id = taskID
            guard let shown = state.cardWriting, shown.isPlain, shown.text != text else { return }
            Task { @MainActor in _ = await model.commitCardWriting(text, for: id) }
        case .tag:
            let name = newTag.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            if !name.isEmpty, let task { model.setCardTags(task.tags + [name]) }
            newTag = ""
            addingTag = false
        case .link:
            if let task, link != (task.url ?? "") { model.setCardLink(link) }
            editingLink = false
        case .subtask:
            // Leaving the field keeps what was typed (Esc means keep).
            if !newSubtask.trimmingCharacters(in: .whitespaces).isEmpty, model.addCardSubtask(newSubtask) { newSubtask = "" }
            addingSubtask = false
        case nil:
            break
        }
    }

    /// Return makes the next subtask; the field stays.
    private func addSubtask() {
        let text = newSubtask
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            addingSubtask = false
            focus = nil
            return
        }
        if model.addCardSubtask(text) { newSubtask = "" }
        focus = .subtask
    }

    /// Esc ends an open subtask, tag or link field (keeping it), then
    /// shrinks full, then closes the card. It never throws anything away.
    private func escape() {
        switch focus {
        case .subtask, .tag, .link:
            focus = nil
        default:
            commit(focus)
            model.escapeCard()
        }
    }
}

/// One photo: its thumbnail, Quick Look on a click.
struct TasksCardThumbnail: View {
    let photo: RemindersReplicaPhoto
    let size: CGSize
    let model: TasksPageModel
    @State private var image: NSImage?

    var body: some View {
        Button { model.previewReplicaPhoto(photo) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.05))
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(photo.filename)
        .task(id: photo.id) {
            guard let url = await model.replicaPhotoURL(photo) else { return }
            let maxPixel = max(size.width, size.height) * 2
            image = await Task.detached(priority: .utility) {
                TasksCardThumbnail.thumbnail(url, maxPixel: maxPixel)
            }.value
        }
    }

    nonisolated static func thumbnail(_ url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}
