import AppKit
import ImageIO
import SwiftUI

/// The replica's detail panel (R2): Reminders' measured field order
/// (R2-08/09) in rounded cards, mapped onto what Attic's task holds. Edits
/// are staged in `RemindersReplicaDetailState` and saved when the panel
/// closes; Escape cancels them (M, R2-F05). Subtask ticks and photos are
/// separate items and apply at once, each through its own producer.
struct RemindersReplicaDetailView: View {
    @ObservedObject var state: RemindersReplicaDetailState
    let model: TasksPageModel
    /// Open the item's own page (its writing is edited there).
    let openPage: () -> Void

    @State private var newTag = ""
    @State private var photos: [RemindersReplicaPhoto] = []
    @State private var subtasksRevision = 0
    @State private var showsCalendar = false

    private typealias M = RemindersReplicaDetailMetrics

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                titleCard
                gap
                notesCard
                heading(String(localized: "Date & Time"))
                dateCard
                heading(String(localized: "Organisation"))
                organisationCard
                gap
                priorityCard
                if !subtasks.isEmpty {
                    heading(String(localized: "Subtasks"))
                    subtasksCard
                }
                gap
                photosCard
            }
            .padding(M.outerInset)
            .frame(width: M.panelWidth, alignment: .leading)
        }
        .frame(width: M.panelWidth)
        .frame(maxHeight: M.maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(RemindersReplicaEscapeCatcher { model.cancelReplicaDetail() })
        .onAppear { photos = model.replicaPhotos(for: state.taskID) }
        .accessibilityIdentifier("replica-detail")
    }

    // MARK: Cards

    private var gap: some View { Color.clear.frame(height: M.cardGap) }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: M.headingSize, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, M.cardInset)
            .padding(.top, M.headingTop)
            .padding(.bottom, M.headingBottom)
            .accessibilityAddTraits(.isHeader)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(width: M.cardWidth, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: M.cardRadius, style: .continuous).fill(M.cardFill))
    }

    private var separator: some View {
        Divider().padding(.leading, M.labelX)
    }

    /// A row: an icon in its column, the label, then the control.
    private func row<Control: View>(_ symbol: String, _ label: String, subtitle: String? = nil,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: M.labelSize))
                .foregroundStyle(.secondary)
                .frame(width: M.iconCentre * 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: M.labelSize))
                if let subtitle {
                    Text(subtitle).font(.system(size: M.subtitleSize)).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, M.labelX - M.iconCentre * 2)
            Spacer(minLength: 8)
            control()
        }
        .padding(.trailing, M.cardInset)
        .frame(height: subtitle == nil ? M.rowHeight : M.subtitledRowHeight)
    }

    private var titleCard: some View {
        card {
            TextField(String(localized: "Title"), text: $state.draft.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: M.labelSize))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(minHeight: M.titleFieldHeight)
                .background(RoundedRectangle(cornerRadius: M.titleFieldRadius, style: .continuous).fill(M.cardFill))
                .padding(M.cardInset)
                .accessibilityIdentifier("replica-detail-title")
        }
    }

    /// M: Notes & URL behind an expander, collapsed at first (R2-08). The
    /// writing belongs to the item's note (one-item rules): it is shown
    /// here with its links clickable and edited on the item's page.
    private var notesCard: some View {
        card {
            Button {
                state.notesExpanded.toggle()
            } label: {
                HStack {
                    Text(String(localized: "Notes"))
                        .font(.system(size: M.labelSize))
                        .foregroundStyle(state.notesExpanded ? .primary : .secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(state.notesExpanded ? 90 : 0))
                }
                .padding(.horizontal, M.cardInset)
                .frame(height: M.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("replica-detail-notes-expander")
            if state.notesExpanded {
                separator
                VStack(alignment: .leading, spacing: 6) {
                    if let notes = model.notePreviews[state.taskID] {
                        Text(RemindersReplicaText.linkedNotes(notes))
                            .font(.system(size: M.labelSize))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("replica-detail-notes")
                    } else {
                        Text(String(localized: "No writing yet"))
                            .font(.system(size: M.labelSize))
                            .foregroundStyle(.tertiary)
                    }
                    Button(String(localized: "Open Page"), action: openPage)
                        .buttonStyle(.link)
                        .font(.system(size: M.subtitleSize))
                }
                .padding(M.cardInset)
            }
        }
    }

    private var dateCard: some View {
        let day = state.draft.dueDay
        return card {
            row("calendar", String(localized: "Date"), subtitle: day.map(longDate)) {
                Toggle("", isOn: Binding(get: { state.draft.dueDay != nil }, set: { on in
                    state.draft.setHasDate(on, today: today)
                    showsCalendar = on
                }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel(String(localized: "Date"))
            }
            .contentShape(Rectangle())
            .onTapGesture { if day != nil { showsCalendar.toggle() } }
            if day != nil, showsCalendar {
                separator
                DatePicker("", selection: Binding(get: { dateValue }, set: { date in
                    state.draft.dueDay = DueDay(date: date, calendar: model.services.calendar())
                }), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(.horizontal, M.cardInset)
                .padding(.vertical, 6)
            }
        }
    }

    private var organisationCard: some View {
        card {
            row("list.bullet", String(localized: "List")) {
                Picker("", selection: $state.draft.list) {
                    ForEach(RemindersReplicaDetailDraft.List.allCases, id: \.self) { list in
                        Text(list.title).tag(list)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .disabled(state.draft.isDone)
                .accessibilityLabel(String(localized: "List"))
            }
            separator
            tagsRow
        }
    }

    /// The tags as chips: a click filters the list by one (Attic's Find),
    /// × removes it; a new one is typed at the end.
    private var tagsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Image(systemName: "number")
                    .font(.system(size: M.labelSize))
                    .foregroundStyle(.secondary)
                    .frame(width: M.iconCentre * 2)
                Text(String(localized: "Tags"))
                    .font(.system(size: M.labelSize))
                    .padding(.leading, M.labelX - M.iconCentre * 2)
                Spacer()
            }
            .frame(height: M.rowHeight)
            if !state.draft.tags.isEmpty {
                RemindersReplicaWrap(spacing: 6) {
                    ForEach(state.draft.tags, id: \.self) { tag in
                        HStack(spacing: 3) {
                            Button("#" + tag) { model.filterReplicaByTag(tag) }
                                .buttonStyle(.plain)
                                .help(String(localized: "Show tasks tagged #\(tag)"))
                            Button {
                                state.draft.removeTag(tag)
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: "Remove #\(tag)"))
                        }
                        .font(.system(size: M.subtitleSize))
                        .foregroundStyle(RemindersReplicaMetrics.tagInk)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(RemindersReplicaMetrics.tagInk.opacity(0.12)))
                    }
                }
                .padding(.leading, M.labelX)
                .padding(.trailing, M.cardInset)
            }
            TextField(String(localized: "Add Tag"), text: $newTag)
                .textFieldStyle(.plain)
                .font(.system(size: M.labelSize))
                .onSubmit {
                    if state.draft.addTag(newTag) { newTag = "" }
                }
                .padding(.leading, M.labelX)
                .padding(.trailing, M.cardInset)
                .padding(.bottom, 10)
                .accessibilityIdentifier("replica-detail-new-tag")
        }
    }

    private var priorityCard: some View {
        card {
            row("exclamationmark", String(localized: "Priority")) {
                Picker("", selection: $state.draft.priority) {
                    ForEach(TaskPriority.allCases) { priority in
                        Text(priority.title).tag(priority)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(String(localized: "Priority"))
            }
        }
    }

    private var subtasks: [TaskItem] {
        _ = subtasksRevision
        return model.store.subtasks(of: state.taskID)
    }

    private var subtasksCard: some View {
        card {
            ForEach(Array(subtasks.enumerated()), id: \.element.id) { index, subtask in
                if index > 0 { separator }
                HStack(spacing: 0) {
                    Button {
                        _ = model.report(model.toggleSubtask(subtask.id), on: state.taskID) { [weak model] in
                            model?.toggleSubtask(subtask.id) ?? .failed(.taskGone)
                        }
                        subtasksRevision &+= 1
                    } label: {
                        RemindersReplicaCircle(done: subtask.status == .done)
                            .frame(width: M.iconCentre * 2, height: M.rowHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(subtask.status == .done ? String(localized: "Mark as not done") : String(localized: "Complete"))
                    Text(subtask.title)
                        .font(.system(size: M.labelSize))
                        .foregroundStyle(subtask.status == .done ? .secondary : .primary)
                        .lineLimit(2)
                        .padding(.leading, M.labelX - M.iconCentre * 2)
                    Spacer(minLength: M.cardInset)
                }
                .frame(minHeight: M.rowHeight)
            }
        }
    }

    /// M: Add Image… is the panel's last control (R2-10); C: the detail's
    /// 29 × 29 thumbnails (N20; shown at that box, E).
    private var photosCard: some View {
        card {
            if !photos.isEmpty {
                RemindersReplicaWrap(spacing: 8) {
                    ForEach(photos) { photo in
                        RemindersReplicaThumbnail(photo: photo, model: model) {
                            Task { @MainActor in
                                if await model.removeReplicaPhoto(photo, from: state.taskID) {
                                    photos.removeAll { $0.id == photo.id }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, M.cardInset)
                .padding(.top, M.cardInset)
                .padding(.bottom, 4)
                separator
            }
            Button {
                model.addReplicaPhoto(to: state.taskID)
            } label: {
                row("photo", String(localized: "Add Photo…")) { EmptyView() }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canAddReplicaPhoto)
            .accessibilityIdentifier("replica-detail-add-photo")
        }
    }

    // MARK: Dates

    private var today: DueDay { DueDay(date: model.services.now(), calendar: model.services.calendar()) }

    private var dateValue: Date {
        let calendar = DueDay.storageCalendar(matching: model.services.calendar())
        return state.draft.dueDay?.startDate(in: calendar) ?? model.services.now()
    }

    /// M: the long date under Date ("Friday, 30 October 2026", R2-08).
    private func longDate(_ day: DueDay) -> String {
        let calendar = DueDay.storageCalendar(matching: model.services.calendar())
        guard let date = day.startDate(in: calendar) else { return day.rawValue }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = model.services.locale
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

/// One photo: the detail's 29 × 29 thumbnail (C generation box, N20);
/// a click opens Quick Look, the menu removes it.
private struct RemindersReplicaThumbnail: View {
    let photo: RemindersReplicaPhoto
    let model: TasksPageModel
    let remove: () -> Void

    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        let box = RemindersReplicaDetailMetrics.photoBox
        Button {
            model.previewReplicaPhoto(photo)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: RemindersReplicaDetailMetrics.photoRadius).fill(Color.black.opacity(0.06))
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(width: box, height: box)
            .clipShape(RoundedRectangle(cornerRadius: RemindersReplicaDetailMetrics.photoRadius))
        }
        .buttonStyle(.plain)
        .help(photo.filename)
        .accessibilityLabel(photo.filename)
        .contextMenu {
            Button(String(localized: "Quick Look")) { model.previewReplicaPhoto(photo) }
            Button(String(localized: "Remove"), role: .destructive, action: remove)
        }
        .task(id: photo.id) {
            guard let url = await model.replicaPhotoURL(photo) else { return }
            let scale = scale
            let thumbnail: CGImage? = await Task.detached(priority: .utility) {
                guard let size = NoteImageDecoder.pixelSize(at: url) else { return nil }
                let pixels = RemindersReplicaPhotoSizing.maxPixel(original: size, box: RemindersReplicaPhotoSizing.detail, scale: scale)
                return NoteImageDecoder.thumbnail(at: url, maxPixel: pixels)
            }.value
            image = thumbnail.map { NSImage(cgImage: $0, size: .zero) }
        }
    }
}

/// Lays chips and thumbnails out in rows that wrap.
struct RemindersReplicaWrap: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// Escape in the panel's window cancels its edits (M, R2-F05), unless an
/// input method is composing (then Escape is the composition's).
struct RemindersReplicaEscapeCatcher: NSViewRepresentable {
    let onEscape: () -> Void

    final class Catcher: NSView {
        var onEscape: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, event.keyCode == 53,
                      event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
                      !TasksPage.isComposing(window.firstResponder) else { return event }
                self.onEscape()
                return nil
            }
        }
    }

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher(frame: .zero)
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) { view.onEscape = onEscape }
}
