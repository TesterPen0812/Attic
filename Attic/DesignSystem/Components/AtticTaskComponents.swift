import SwiftUI

// MARK: - Status circle

/// The status circle shows and changes a task's state (spec § The status
/// circle): to do is an empty ring in the priority colour, in progress is
/// half filled, done is filled with a check that draws itself, backlog is a
/// dashed ring. Completing is one moment: the fill fades in, the check
/// draws and the haptic tick lands together.
struct AtticStatusCircle: View {
    let state: AtticTaskState
    let priority: AtticPriority
    /// Pin the check's drawing progress (gallery); nil animates live.
    var checkProgress: Double?

    @Environment(\.atticDesign) private var design
    @State private var drawnCheck: Double = 1
    @State private var fillOpacity: Double = 1
    @State private var probeID = UUID()

    var body: some View {
        let tokens = design.tokens
        let colour = tokens.priority(priority)
        let lineWidth: CGFloat = design.increaseContrast ? 2 : 1.5
        let size = AtticControlSize.statusCircle
        ZStack {
            switch state {
            case .todo:
                Circle().inset(by: 0.5 + lineWidth / 2).stroke(colour.color, lineWidth: lineWidth)
            case .inProgress:
                Circle().inset(by: 0.5 + lineWidth / 2).stroke(colour.color, lineWidth: lineWidth)
                AtticHalfDisc().fill(colour.color).padding(0.5 + lineWidth + 1.75)
            case .done:
                Circle().inset(by: 0.5).fill(tokens.color(.doneFill)).opacity(fillOpacity)
                AtticCheckShape()
                    .trim(from: 0, to: checkProgress ?? drawnCheck)
                    .stroke(tokens.color(.onDone), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .padding(4.25)
            case .backlog:
                Circle().inset(by: 0.5 + lineWidth / 2)
                    .stroke(colour.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [2.1, 2.3]))
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .trailing) {
            if design.differentiateWithoutColor, priority.markCount > 0, state != .done {
                AtticPriorityMark(count: priority.markCount, colour: colour).offset(x: 5)
            }
        }
        .onChange(of: state) { old, new in
            guard new == .done, old != .done else { return }
            AtticHaptics.tick(enabled: design.hapticsEnabled)
            guard checkProgress == nil else { return }
            if design.reduceMotion {
                fillOpacity = 0
                drawnCheck = 1
                withAnimation(AtticMotionPreset.complete.animation(reduceMotion: true)) { fillOpacity = 1 }
            } else {
                drawnCheck = 0
                fillOpacity = 0
                withAnimation(AtticMotionPreset.complete.animation(reduceMotion: false)) {
                    drawnCheck = 1
                    fillOpacity = 1
                }
            }
        }
        .atticProbe { [probeID] specimen in
            AtticProbe(
                id: probeID, kind: .icon(name: "status circle"),
                ink: state == .done ? .doneFill : Self.ink(for: priority),
                foreground: state == .done ? tokens.ink(.doneFill) : colour,
                specimen: specimen
            )
        }
        .accessibilityHidden(true)
    }

    static func ink(for priority: AtticPriority) -> AtticInk {
        switch priority {
        case .none: .priorityNone
        case .low: .priorityLow
        case .medium: .priorityMedium
        case .high: .priorityHigh
        }
    }
}

/// The left half of a disc (in progress).
struct AtticHalfDisc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addArc(center: centre, radius: min(rect.width, rect.height) / 2, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// A check mark drawn as one stroke, so `trim` can draw it.
struct AtticCheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.84))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.94, y: rect.minY + rect.height * 0.18))
        return path
    }
}

/// Differentiate Without Colour: one to three dots beside the circle.
private struct AtticPriorityMark: View {
    let count: Int
    let colour: AtticRGBA

    var body: some View {
        VStack(spacing: 1.5) {
            ForEach(0..<count, id: \.self) { _ in
                Circle().fill(colour.color).frame(width: 2.5, height: 2.5)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The circle as a button with its hit area, VoiceOver name and actions.
struct AtticStatusButton: View {
    let state: AtticTaskState
    let priority: AtticPriority
    var onAdvance: () -> Void = {}
    var onComplete: () -> Void = {}

    var body: some View {
        Button(action: onAdvance) {
            AtticStatusCircle(state: state, priority: priority)
                .frame(width: AtticControlSize.minimumHitTarget, height: AtticControlSize.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(String(localized: "Status"))
        .accessibilityValue([state.spokenName, priority.spokenName].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAction(named: Text("Complete"), onComplete)
    }
}

// MARK: - Status tabs

/// The quiet Now · Backlog · Done switch under the header: 13 pt, 14 pt
/// apart; the selected tab is the body colour in medium weight, with no
/// underline; counts are set apart from their labels.
struct AtticStatusTabs<Tab: Hashable>: View {
    struct Item: Identifiable {
        let tab: Tab
        let title: String
        let count: Int?
        var id: String { title }
    }

    let items: [Item]
    @Binding var selection: Tab

    @Environment(\.atticDesign) private var design

    var body: some View {
        HStack(spacing: AtticLayout.statusTabsGap) {
            ForEach(items) { item in
                AtticStatusTab(item: item, isSelected: item.tab == selection) {
                    withAnimation(AtticMotionPreset.slide.animation(reduceMotion: design.reduceMotion)) {
                        selection = item.tab
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct AtticStatusTab<Tab: Hashable>: View {
    let item: AtticStatusTabs<Tab>.Item
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.atticForcedState) private var forced
    @Environment(\.isFocused) private var isFocused
    @State private var hovered = false

    var body: some View {
        let state = AtticStateResolver(forced: forced, isEnabled: true, isHovered: hovered, isPressed: false, isFocused: isFocused).state
        Button(action: action) {
            HStack(spacing: 4) {
                AtticText(
                    verbatim: item.title,
                    style: isSelected ? .statusTabSelected : .statusTab,
                    ink: isSelected || state == .hover ? .body : .helper
                )
                if let count = item.count {
                    AtticText(verbatim: "\(count)", style: .statusCount, ink: .helper)
                }
            }
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .atticFocusRing(state == .focused, cornerRadius: 4)
        .onHover { hovered = $0 }
        .accessibilityLabel(item.title)
        .accessibilityValue(item.count.map { String(localized: "\($0) tasks") } ?? "")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Task row

/// What a task row shows. The design system's own model: Phase 1 fills it
/// from the store.
struct AtticTaskRowModel: Identifiable, Sendable {
    struct Due: Sendable {
        let text: String
        /// Overdue and today are red; tomorrow, this week and later are quiet.
        let isUrgent: Bool
    }

    var id = UUID()
    var title: String
    var state: AtticTaskState = .todo
    var priority: AtticPriority = .none
    var due: Due?
    var tags: [String] = []
    var attachments = 0
    var links = 0
    var subtasks: (done: Int, total: Int)?
    var inWindow = false

    var hasDetails: Bool {
        state != .done && (due != nil || !tags.isEmpty || attachments > 0 || links > 0 || inWindow)
    }

    var accessibilityDescription: String {
        var parts = [title, state.spokenName]
        if let spoken = priority.spokenName { parts.append(spoken) }
        if let due { parts.append(String(localized: "due \(due.text)")) }
        if !tags.isEmpty { parts.append(String(localized: "tagged \(tags.joined(separator: ", "))")) }
        if let subtasks { parts.append(String(localized: "\(subtasks.done) of \(subtasks.total) subtasks")) }
        return parts.joined(separator: ", ")
    }
}

/// A task row: 32 pt (30 highlight + 2), 44 pt with a details line; the
/// circle at x = 16 and the title at x = 42; highlight inset 8, radius 10.
/// Three click targets: the circle, the subtask count, and the rest.
struct AtticTaskRow: View {
    let model: AtticTaskRowModel
    var isSelected = false
    var selectionRun: AtticSelectionRun = .single
    var isExpanded = false
    /// "Add to page" while a file hovers over the row.
    var dropLabel: String?
    var onAdvance: () -> Void = {}
    var onToggleExpanded: () -> Void = {}
    var onOpen: () -> Void = {}

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var hovered = false
    @State private var probeID = UUID()

    var body: some View {
        let tokens = design.tokens
        let state = AtticStateResolver(forced: forced, isEnabled: isEnabled, isHovered: hovered, isPressed: false, isFocused: isFocused).state
        let twoLine = model.hasDetails
        let highlightHeight = twoLine ? AtticLayout.detailRowHighlightHeight : AtticLayout.rowHighlightHeight
        let pitch = twoLine ? AtticLayout.detailRowPitch : AtticLayout.rowPitch
        let fill: AtticRGBA? = if state == .pressed {
            tokens.pressed
        } else if isSelected {
            tokens.selected
        } else if state == .hover {
            tokens.hover
        } else {
            nil
        }
        let disabled = state == .disabled
        let done = model.state == .done

        ZStack(alignment: .topLeading) {
            Group {
                if let fill {
                    AtticHighlight(fill: fill, run: isSelected ? selectionRun : .single)
                }
                if dropLabel != nil {
                    AtticDropOutline()
                }
            }
            .frame(height: highlightHeight)
            .padding(.horizontal, AtticLayout.rowHighlightInset)

            HStack(alignment: .top, spacing: 0) {
                AtticStatusButton(state: model.state, priority: model.priority, onAdvance: onAdvance, onComplete: onAdvance)
                    .padding(.leading, AtticLayout.circleX - (AtticControlSize.minimumHitTarget - AtticControlSize.statusCircle) / 2)
                    .padding(.top, (AtticLayout.rowHighlightHeight - AtticControlSize.minimumHitTarget) / 2 + (twoLine ? -1 : 0))
                    .opacity(disabled ? 0.45 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    AtticText(
                        verbatim: model.title,
                        style: .rowTitle,
                        ink: disabled ? .disabled : (done ? .helper : .body),
                        strikethrough: done,
                        truncates: true
                    )
                    .frame(height: twoLine ? 18 : AtticLayout.rowHighlightHeight)
                    if twoLine {
                        AtticTaskDetails(model: model, disabled: disabled)
                            .frame(height: 16)
                    }
                }
                .padding(.leading, AtticLayout.textX - AtticLayout.circleX - AtticControlSize.minimumHitTarget + (AtticControlSize.minimumHitTarget - AtticControlSize.statusCircle) / 2)
                .padding(.top, twoLine ? 5 : 0)
                Spacer(minLength: 8)
                trailing(disabled: disabled, twoLine: twoLine)
            }
        }
        .frame(height: pitch, alignment: .top)
        .padding(.top, 1)
        .frame(height: pitch)
        .overlay(alignment: .top) {
            if state == .focused {
                Color.clear
                    .frame(height: highlightHeight)
                    .atticFocusRing(true, cornerRadius: AtticRadius.highlight)
                    .padding(.horizontal, AtticLayout.rowHighlightInset)
                    .padding(.top, 1)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.accessibilityDescription)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text("Open page"), onOpen)
        .atticControlProbe(
            twoLine ? "Task row (details)" : "Task row", id: probeID,
            expectedSize: CGSize(width: 0, height: pitch), radius: AtticRadius.highlight, expectedRadius: 10
        )
    }

    @ViewBuilder
    private func trailing(disabled: Bool, twoLine: Bool) -> some View {
        if let dropLabel {
            AtticText(verbatim: dropLabel, style: .dropLabel, ink: .accentText, allowsOverlap: true)
                .frame(height: AtticLayout.rowHighlightHeight)
                .padding(.trailing, AtticLayout.rowHighlightInset + 10)
        } else if let subtasks = model.subtasks, model.state != .done {
            AtticSubtaskCountButton(done: subtasks.done, total: subtasks.total, isExpanded: isExpanded, disabled: disabled, action: onToggleExpanded)
                .padding(.trailing, AtticLayout.rowHighlightInset + 2)
        }
    }
}

/// The details line: due date, tags, files and links, only when present.
private struct AtticTaskDetails: View {
    let model: AtticTaskRowModel
    let disabled: Bool

    var body: some View {
        HStack(spacing: 0) {
            let parts = segments
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    AtticText(verbatim: " · ", style: .rowMeta, ink: disabled ? .disabled : .helper)
                }
                part
            }
        }
    }

    private var segments: [AnyView] {
        var parts: [AnyView] = []
        if model.inWindow {
            parts.append(AnyView(HStack(spacing: 3) {
                AtticIcon(systemName: "macwindow", size: 10, ink: disabled ? .disabled : .icon)
                AtticText("In window", style: .rowMeta, ink: disabled ? .disabled : .helper)
            }))
        }
        if let due = model.due {
            parts.append(AnyView(AtticText(verbatim: due.text, style: .rowMeta, ink: disabled ? .disabled : (due.isUrgent ? .dueText : .helper))))
        }
        for tag in model.tags {
            parts.append(AnyView(AtticText(verbatim: "#" + tag, style: .rowMeta, ink: disabled ? .disabled : .accentText)))
        }
        if model.attachments > 0 {
            parts.append(AnyView(HStack(spacing: 2) {
                AtticIcon(systemName: "paperclip", size: 10, ink: disabled ? .disabled : .icon)
                AtticText(verbatim: "\(model.attachments)", style: .rowMeta, ink: disabled ? .disabled : .helper)
            }))
        }
        if model.links > 0 {
            parts.append(AnyView(AtticText(verbatim: String(localized: "\(model.links) links"), style: .rowMeta, ink: disabled ? .disabled : .helper)))
        }
        return parts
    }
}

/// "1/3 ›": the second click target, which opens the quick look.
private struct AtticSubtaskCountButton: View {
    let done: Int
    let total: Int
    let isExpanded: Bool
    let disabled: Bool
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                AtticText(verbatim: "\(done)/\(total)", style: .count, ink: disabled ? .disabled : .helper)
                ZStack {
                    if isExpanded {
                        AtticIcon(systemName: "chevron.down", size: 9, weight: .semibold, ink: disabled ? .disabled : .chevron)
                            .transition(.opacity)
                    } else {
                        AtticIcon(systemName: "chevron.right", size: 9, weight: .semibold, ink: disabled ? .disabled : .chevron)
                            .transition(.opacity)
                    }
                }
                .frame(width: 10)
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: AtticRadius.control(height: 22), style: .continuous)
                    .fill((hovered ? design.tokens.chipHover : .clear).color)
            )
            .frame(height: AtticLayout.rowHighlightHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .help(isExpanded ? String(localized: "Hide subtasks") : String(localized: "Show subtasks"))
        .accessibilityLabel(String(localized: "\(done) of \(total) subtasks"))
        .accessibilityHint(isExpanded ? String(localized: "Collapses the quick look") : String(localized: "Expands the quick look"))
    }
}

// MARK: - Quick look and subtasks

/// A subtask's rounded-square checkbox (tasks keep circles, so the two never
/// look alike).
struct AtticSubtaskCheckbox: View {
    let isDone: Bool

    @Environment(\.atticDesign) private var design
    @State private var probeID = UUID()

    var body: some View {
        let tokens = design.tokens
        let size = AtticControlSize.subtaskCheckbox
        let shape = RoundedRectangle(cornerRadius: AtticRadius.subtaskCheckbox, style: .continuous)
        let lineWidth: CGFloat = design.increaseContrast ? 1.8 : 1.3
        ZStack {
            if isDone {
                shape.fill(tokens.color(.doneFill))
                AtticCheckShape()
                    .stroke(tokens.color(.onDone), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .padding(3.5)
            } else {
                shape.inset(by: lineWidth / 2).stroke(tokens.color(.priorityNone), lineWidth: lineWidth)
            }
        }
        .frame(width: size, height: size)
        .atticProbe { [probeID] specimen in
            AtticProbe(
                id: probeID, kind: .icon(name: "subtask checkbox"),
                ink: isDone ? .doneFill : .priorityNone,
                foreground: tokens.ink(isDone ? .doneFill : .priorityNone), specimen: specimen
            )
        }
        .accessibilityHidden(true)
    }
}

struct AtticSubtaskModel: Identifiable, Sendable {
    var id = UUID()
    var title: String
    var isDone = false
}

/// One subtask line: checkbox and title, 28 pt pitch.
struct AtticSubtaskRow: View {
    let subtask: AtticSubtaskModel
    var onToggle: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                AtticSubtaskCheckbox(isDone: subtask.isDone)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, -4)
            AtticText(verbatim: subtask.title, style: .body, ink: subtask.isDone ? .helper : .body, strikethrough: subtask.isDone, truncates: true)
            Spacer(minLength: 0)
        }
        .frame(height: AtticLayout.subtaskPitch)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(subtask.title)
        .accessibilityValue(subtask.isDone ? String(localized: "done") : String(localized: "to do"))
        .accessibilityAction(named: Text(subtask.isDone ? "Mark as not done" : "Mark as done"), onToggle)
    }
}

/// The quick look: the row expands in place into its subtasks, "Add
/// subtask" and "Open page". Aligned to the row's text column.
struct AtticQuickLook: View {
    let subtasks: [AtticSubtaskModel]
    var onToggle: (AtticSubtaskModel) -> Void = { _ in }
    var onAddSubtask: () -> Void = {}
    var onOpenPage: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(subtasks) { subtask in
                AtticSubtaskRow(subtask: subtask) { onToggle(subtask) }
            }
            AtticQuietAction(systemName: "plus", title: String(localized: "Add subtask"), action: onAddSubtask)
            AtticQuietAction(systemName: nil, title: String(localized: "Open page"), trailingChevron: true, emphasised: true, action: onOpenPage)
        }
        .padding(.leading, AtticLayout.textX)
        .padding(.trailing, AtticLayout.rowHighlightInset)
        .padding(.bottom, 4)
    }
}

/// A quiet text action inside content ("Add subtask", "Open page"): no
/// raised material, a hover fill, helper or label ink.
struct AtticQuietAction: View {
    let systemName: String?
    let title: String
    var trailingChevron = false
    var emphasised = false
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @State private var hovered = false

    var body: some View {
        let hover = forced == .hover || hovered
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemName {
                    AtticIcon(systemName: systemName, size: 12, weight: .medium, ink: .icon)
                        .frame(width: 14)
                }
                AtticText(verbatim: title, style: emphasised ? .controlLabel : .body, ink: emphasised ? .label : .helper)
                if trailingChevron {
                    AtticIcon(systemName: "chevron.right", size: 9, weight: .semibold, ink: .chevron)
                        .padding(.leading, -4)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: AtticRadius.control(height: 24), style: .continuous)
                    .fill((hover ? design.tokens.chipHover : .clear).color)
            )
            .padding(.horizontal, -6)
            .frame(height: AtticLayout.subtaskPitch)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Task card

/// The task card that lives in notes and task pages: recessed and flat
/// inside content (radius 10, no border). Collapsed: circle, title and a
/// details line when there are details. Expanded: subtasks you can tick,
/// "Add subtask", then "Open in Tasks" and "Open page".
struct AtticTaskCard: View {
    let model: AtticTaskRowModel
    var subtasks: [AtticSubtaskModel] = []
    var isExpanded = false
    var onToggleExpanded: () -> Void = {}
    var onAdvance: () -> Void = {}

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @State private var hovered = false
    @State private var probeID = UUID()

    var body: some View {
        let tokens = design.tokens
        let shape = RoundedRectangle(cornerRadius: AtticRadius.tile, style: .continuous)
        let hover = forced == .hover || hovered
        let fill = hover ? tokens.hover.over(tokens.recessed) : tokens.recessed
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                AtticStatusButton(state: model.state, priority: model.priority, onAdvance: onAdvance, onComplete: onAdvance)
                    .padding(.leading, 12 - (AtticControlSize.minimumHitTarget - AtticControlSize.statusCircle) / 2)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    AtticText(verbatim: model.title, style: .rowTitle, ink: model.state == .done ? .helper : .body, strikethrough: model.state == .done, truncates: true)
                        .frame(height: 30)
                    if model.hasDetails || model.subtasks != nil {
                        AtticCardDetails(model: model)
                            .frame(height: 16)
                            .padding(.top, -6)
                            .padding(.bottom, 6)
                    }
                }
                .padding(.leading, 4)
                Spacer(minLength: 8)
                Button(action: onToggleExpanded) {
                    ZStack {
                        if isExpanded {
                            AtticIcon(systemName: "chevron.up", size: 10, weight: .semibold, ink: .chevron).transition(.opacity)
                        } else {
                            AtticIcon(systemName: "chevron.down", size: 10, weight: .semibold, ink: .chevron).transition(.opacity)
                        }
                    }
                    .frame(width: 28, height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? String(localized: "Collapse") : String(localized: "Expand"))
                .padding(.trailing, 4)
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(subtasks) { AtticSubtaskRow(subtask: $0) }
                    AtticQuietAction(systemName: "plus", title: String(localized: "Add subtask"), action: {})
                    HStack {
                        AtticQuietAction(systemName: nil, title: String(localized: "Open in Tasks"), emphasised: true, action: {})
                        Spacer()
                        AtticQuietAction(systemName: "doc.text", title: String(localized: "Open page"), emphasised: true, action: {})
                    }
                    .padding(.top, 4)
                }
                .padding(.leading, 38)
                .padding(.trailing, 12)
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .background {
            ZStack {
                shape.fill(fill.color)
                if let border = tokens.recessedBorder { shape.strokeBorder(border.color, lineWidth: 1) }
            }
        }
        .contentShape(shape)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.accessibilityDescription + ", " + String(localized: "card"))
        .atticControlProbe("Task card", id: probeID, expectedSize: nil, radius: AtticRadius.tile, expectedRadius: AtticRadius.tile)
    }
}

private struct AtticCardDetails: View {
    let model: AtticTaskRowModel

    var body: some View {
        HStack(spacing: 6) {
            if let due = model.due {
                HStack(spacing: 3) {
                    AtticIcon(systemName: "calendar", size: 10, ink: due.isUrgent ? .priorityHigh : .icon)
                    AtticText(verbatim: due.text, style: .rowMeta, ink: due.isUrgent ? .dueText : .helper)
                }
            }
            ForEach(model.tags, id: \.self) { AtticTagChip(name: $0) }
            if let subtasks = model.subtasks {
                AtticText(verbatim: "\(subtasks.done)/\(subtasks.total)", style: .count, ink: .helper)
            }
        }
    }
}

// MARK: - Tag

/// A tag: the accent (grey on Original), sentence of `#word`. `inline` is
/// plain text for details lines; `chip` is a recessed pill that follows the
/// control corner rule (18 tall, radius 6).
struct AtticTagChip: View {
    enum Style { case chip, inline }

    let name: String
    var style: Style = .chip
    var isSelected = false

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @State private var hovered = false
    @State private var probeID = UUID()

    var body: some View {
        let tokens = design.tokens
        let height = AtticControlSize.tagHeight
        let radius = AtticRadius.control(height: height)
        let hover = forced == .hover || hovered
        let fill: AtticRGBA = isSelected ? tokens.tagFillSelected : (hover ? tokens.hover.over(tokens.tagFill) : tokens.tagFill)
        switch style {
        case .inline:
            AtticText(verbatim: "#" + name, style: .rowMeta, ink: .accentText)
        case .chip:
            AtticText(verbatim: "#" + name, style: .tag, ink: .accentText)
                .padding(.horizontal, 6)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill.color))
                .onHover { hovered = $0 }
                .accessibilityLabel(String(localized: "Tag \(name)"))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .atticControlProbe("Tag", id: probeID, expectedSize: nil, radius: radius, expectedRadius: 6)
        }
    }
}
