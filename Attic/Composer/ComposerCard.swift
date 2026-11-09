import AppKit
import SwiftUI

/// One of the "+" card's quiet text buttons (Accepted 2026-11-09, option A
/// in `composer-buttons-drafts.html`): no fill at rest; the hover is a soft
/// wash that hugs the icon and label, and takes them to the heading ink.
/// The hover is held here so moving over a button redraws only this button.
private struct ComposerChipFace<Label: View>: View {
    let open: Bool
    @ViewBuilder let label: (_ hovered: Bool) -> Label

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @State private var pointerInside = false

    var body: some View {
        let hovered = forced == .hover || pointerInside
        label(hovered)
            .background {
                Squircle(cornerRadius: ComposerMetrics.chipHeight / 2, exponent: AtticShape.controlExponent)
                    .fill(ComposerChipLook.fill(open: open, hovered: hovered, tokens: design.tokens).color)
                    // On the wash alone: the card's own frame never animates from here.
                    .animation(design.reduceMotion ? nil : AtticMotionScale.easeOut(AtticMotionScale.fast), value: hovered)
            }
            .onHover { pointerInside = $0 }
    }
}

/// The look of a "+" card button. The wash is the card's heading ink, so it
/// reads in Light and Dark.
enum ComposerChipLook {
    /// Option A's hover: half today's 7.5 % (Accepted 2026-11-09).
    static let hoverAlpha: Double = 0.04
    /// The button whose picker is open keeps its 6 %.
    static let openAlpha: Double = 0.06

    static func fill(open: Bool, hovered: Bool, tokens: AtticColorTokens) -> AtticRGBA {
        tokens.ink(.heading).withAlpha(open ? openAlpha : (hovered ? hoverAlpha : 0))
    }

    /// An unset button is quiet until the pointer is on it.
    static func ink(set: Bool, hovered: Bool, heading: AtticRGBA, muted: AtticRGBA) -> AtticRGBA {
        set || hovered ? heading : muted
    }
}

/// The design's numbers for the "+" card (P4 in `plus-inline-drafts.html`,
/// P1's in-page card `.ic`/`.ib`, drawn at 2x; halved here): 289 × 90 pt.
enum ComposerMetrics {
    static let width: CGFloat = 289
    /// 9 + 20 (title) + 5 + 15 (writing) + 5 + 28 (Create) + 8.
    static let height: CGFloat = 90
    /// Curve 1.4, as the "+" it grows out of (Shapes; owner notes 31 Oct).
    static let radius: CGFloat = ComposerGrow.openRadius
    static let padding = EdgeInsets(top: 9, leading: 14, bottom: 8, trailing: 11)
    static let kindInset: CGFloat = 2
    static let kindButton: CGFloat = 18
    static let kindGap: CGFloat = 1
    static let kindTop: CGFloat = 10
    static let markSlot: CGFloat = 14
    static let markGap: CGFloat = 8
    static let titleHeight: CGFloat = 20
    static let writingTop: CGFloat = 5
    static let writingLeading: CGFloat = markSlot + markGap
    static let writingMinHeight: CGFloat = 15
    static let writingMaxLines = 5
    /// The gap above the chips (`.ic .acts` margin-top 10 px).
    static let actionsTop: CGFloat = 5
    /// A long title wraps onto a second line in the writing line's space
    /// (B1), so the card keeps its height.
    static let titleMaxLines = 2
    static let chipHeight: CGFloat = 26
    static let chipPadding: CGFloat = 5
    static let chipGap: CGFloat = 2
    static let chipIcon: CGFloat = 10
    static let chipLeading: CGFloat = -6
    static let createHeight: CGFloat = 28
    static let createPadding: CGFloat = 10

    /// The switch's room at the end of the title line.
    static func titleTrailing(kinds: Int) -> CGFloat {
        kinds > 1 ? CGFloat(kinds) * (kindButton + kindGap) + kindInset * 2 + padding.trailing : 0
    }
}

/// The card's motion on the app's existing curve for a card that grows
/// (`expand`); instant under Reduce Motion.
enum ComposerMotion {
    @MainActor
    static func animation(showing: Bool = true) -> Animation? {
        AtticMotionPreset.expand.animation(reduceMotion: AtticMotionPreference.reducesMotion, showing: showing)
    }
}

/// The "+" card: the title line with its live tints, the writing, one row of
/// chips and Create, and the kind switch in the top-right corner. It mounts on
/// its own; the panel decides where it sits and how it grows.
private struct ComposerChrome: ViewModifier {
    let drawn: Bool

    func body(content: Content) -> some View {
        if drawn {
            content
                .atticRaisedMaterial(cornerRadius: ComposerMetrics.radius, interactive: false)
                .atticDesignCorners()
        } else {
            content
        }
    }
}

struct ComposerCard: View {
    @ObservedObject var model: ComposerModel
    @ObservedObject var title: TasksAddBarState

    @Environment(\.atticDesign) private var design
    /// The card is kept built while closed (A11): the title asks for the
    /// keyboard only as the card opens (`focusRequest`), never on mount.
    @State private var titleFocused = false
    @FocusState private var writingFocused: Bool
    @FocusState private var keyboardStop: KeyboardStop?
    /// The title field's wrapped height (one line: `titleHeight`).
    @State private var titleFieldHeight = ComposerMetrics.titleHeight
    @State private var open: Chip?
    /// The priority just picked, highlighted on the row until it closes
    /// (Accepted 2026-11-04, #3: Low clicked, None stayed lit).
    @State private var pickedPriority: TaskPriority?
    @State private var priorityPickGeneration = 0

    enum Chip: Hashable { case date, priority, tags, pin, length, calendar }
    private enum KeyboardStop: Hashable { case chip(Chip), create }

    private var keyboardStops: [KeyboardStop] {
        switch model.kind {
        case .task: [.chip(.date), .chip(.priority), .chip(.tags), .create]
        case .note: [.chip(.pin), .chip(.tags), .create]
        case .event:
            [.chip(.date)] + (model.values.time == nil ? [] : [.chip(.length)]) + [.chip(.calendar), .create]
        }
    }

    /// False inside the panel's grow (`ComposerOverlay`), which draws the
    /// material itself so size and radius move together.
    let drawsChrome: Bool

    init(model: ComposerModel, drawsChrome: Bool = true) {
        self.model = model
        self.title = model.title
        self.drawsChrome = drawsChrome
    }

    var body: some View {
        let kind = model.kind
        VStack(alignment: .leading, spacing: 0) {
            titleLine(kind)
            if !titleTakesWritingSpace {
                writingLine(kind)
                    .padding(.top, ComposerMetrics.writingTop)
                    .padding(.leading, ComposerMetrics.writingLeading)
            }
            actions(kind)
                .padding(.top, ComposerMetrics.actionsTop)
        }
        .padding(ComposerMetrics.padding)
        .frame(width: ComposerMetrics.width, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if model.kinds.count > 1 {
                kindSwitch
                    .padding(.top, ComposerMetrics.kindTop)
                    .padding(.trailing, ComposerMetrics.padding.trailing)
            }
        }
        .animation(ComposerMotion.animation(), value: kind)
        .modifier(ComposerChrome(drawn: drawsChrome))
        // Closing: still drawn for the shrink, but takes no input.
        .disabled(!model.isOpen)
        .onAppear { if model.isOpen { titleFocused = true } }
        .onChange(of: model.isOpen) { _, isOpen in
            guard !isOpen else { return }
            open = nil
            priorityPickGeneration &+= 1
            pickedPriority = nil
            titleFocused = false
            writingFocused = false
            keyboardStop = nil
        }
        .onChange(of: model.kind) { _, _ in open = nil; keyboardStop = nil }
        .onChange(of: open) { _, newPicker in
            priorityPickGeneration &+= 1
            if newPicker != .priority { pickedPriority = nil }
        }
        .onChange(of: model.focusRequest) { _, _ in
            titleFocused = true
            if let field = model.editor.textView, let window = field.window, window.firstResponder !== field {
                window.makeFirstResponder(field)
            }
        }
        .onKeyPress(.escape) {
            guard open == nil else { open = nil; return .handled }
            model.close()
            return .handled
        }
        // Native text-field Tabbing can skip plain SwiftUI buttons when the
        // Mac has text-fields-only keyboard navigation. Give each card action
        // an explicit keyboard stop; Tab after Create leaves for the panel.
        .background(ComposerTabTrap(active: model.isOpen && (writingFocused || keyboardStop != nil),
                                    onTab: advanceKeyboard))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "New \(kind.title)"))
        .accessibilityIdentifier("composer-card")
        // The pickers open from the whole card, above it, so they never
        // cover the card they edit (Accepted 2026-11-04, #4), and solid
        // all the way in and out (#5).
        .modifier(ComposerPickers(open: $open, label: pickerLabel) { picker($0) })
    }

    private var pickerLabel: String {
        switch open {
        case .date: dateLabel(model.values)
        case .tags: String(localized: "Tags")
        case .length: Self.length(model.eventLength)
        case .calendar: model.selectedCalendar?.title ?? String(localized: "Calendar")
        default: ""
        }
    }

    /// B1: a title too long for one line wraps into the writing line's
    /// space while the writing is empty and not being typed in, so the card
    /// keeps its height. With writing, the card grows by the line instead.
    private var titleWraps: Bool { titleFieldHeight > ComposerMetrics.titleHeight + 0.5 }
    private var titleTakesWritingSpace: Bool {
        Self.titleTakesWritingSpace(titleWraps: titleWraps, writing: model.writing, writingFocused: writingFocused)
    }

    nonisolated static func titleTakesWritingSpace(titleWraps: Bool, writing: String, writingFocused: Bool) -> Bool {
        titleWraps && writing.isEmpty && !writingFocused
    }

    /// The title line's height: one line, or two in the writing line's room.
    private var titleLineHeight: CGFloat {
        guard titleWraps else { return ComposerMetrics.titleHeight }
        return titleTakesWritingSpace
            ? ComposerMetrics.titleHeight + ComposerMetrics.writingTop + ComposerMetrics.writingMinHeight
            : titleFieldHeight
    }

    /// Tab and ⇧Tab stay inside the card (A4): the title and the writing
    /// line take turns.
    private func moveKeyboard(toWriting: Bool) {
        keyboardStop = nil
        if toWriting {
            titleFocused = false
            writingFocused = true
        } else {
            writingFocused = false
            titleFocused = true
            if let field = model.editor.textView, let window = field.window, window.firstResponder !== field {
                window.makeFirstResponder(field)
            }
        }
    }

    /// Returns false after the final button so AppKit can move focus out
    /// through the panel's normal next-key-view chain.
    @discardableResult
    private func advanceKeyboard(backward: Bool) -> Bool {
        if writingFocused {
            if backward { moveKeyboard(toWriting: false) }
            else {
                writingFocused = false
                titleFocused = false
                keyboardStop = keyboardStops.first
            }
            return true
        }
        guard let keyboardStop, let index = keyboardStops.firstIndex(of: keyboardStop) else { return false }
        let next = index + (backward ? -1 : 1)
        if next < 0 { moveKeyboard(toWriting: true); return true }
        guard keyboardStops.indices.contains(next) else {
            self.keyboardStop = nil
            return false
        }
        self.keyboardStop = keyboardStops[next]
        return true
    }

    // MARK: Kind switch

    private var kindSwitch: some View {
        HStack(spacing: ComposerMetrics.kindGap) {
            ForEach(model.kinds, id: \.self) { kind in
                let selected = model.kind == kind
                Button {
                    model.choose(kind)
                    titleFocused = true
                } label: {
                    AtticIcon(systemName: Self.symbol(kind), size: 10.5, weight: .medium, ink: .glyph)
                        .colour(selected ? design.tokens.ink(.heading) : TasksPanelDesign.toneInk(.meta, tokens: design.tokens))
                        .frame(width: ComposerMetrics.kindButton, height: ComposerMetrics.kindButton)
                        .background {
                            if selected {
                                Squircle(cornerRadius: ComposerMetrics.kindButton / 2, exponent: AtticShape.controlExponent)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(kind.title)
                .accessibilityLabel(kind.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("composer-kind-\(kind.rawValue)")
            }
        }
        .padding(ComposerMetrics.kindInset)
        .background(
            Squircle(cornerRadius: ComposerMetrics.kindButton / 2 + ComposerMetrics.kindInset, exponent: AtticShape.controlExponent)
                .fill(Color.black.opacity(0.045))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Item type"))
    }

    static func symbol(_ kind: ComposerKind) -> String {
        switch kind {
        case .task: "checkmark.circle"
        case .event: "calendar"
        case .note: "doc"
        }
    }

    // MARK: Title

    private func titleLine(_ kind: ComposerKind) -> some View {
        HStack(alignment: .top, spacing: ComposerMetrics.markGap) {
            mark(kind)
                .frame(width: ComposerMetrics.markSlot, height: ComposerMetrics.markSlot)
                .frame(height: ComposerMetrics.titleHeight)
            AtticTokenField(
                text: $title.text.text,
                chips: model.chips,
                isFocused: $titleFocused,
                accessibilityLabel: String(localized: "Title"),
                actions: titleActions,
                style: .composerTitle,
                ink: .heading,
                pieceInk: .placeholder,
                editor: model.editor,
                accessibilityIdentifier: "composer-title",
                growth: AtticTokenFieldGrowth(height: $titleFieldHeight, minHeight: ComposerMetrics.titleHeight,
                                              maxLines: ComposerMetrics.titleMaxLines),
                acceptsKeyboard: model.isOpen
            )
            .frame(height: titleLineHeight, alignment: .top)
            .overlay(alignment: .leading) {
                if title.text.text.isEmpty {
                    AtticText(verbatim: kind.placeholder, style: .composerTitle, ink: .placeholder)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        // Task ↔ Note: one placeholder at a time.
                        .id(kind)
                        .transition(PanelTakeTurns.transition(reduceMotion: design.reduceMotion))
                }
            }
        }
        .simultaneousGesture(TapGesture().onEnded {
            if open == .priority { open = nil }
        })
        .padding(.trailing, ComposerMetrics.titleTrailing(kinds: model.kinds.count))
        .atticDropdown(isPresented: Binding(get: { suggestion != nil }, set: { shown in
            if !shown, let suggestion { title.hiddenSuggestion = suggestion.range }
        }), prefer: .above, label: String(localized: "Suggestions"), takesKeyboard: false, contentHasCard: true,
                       contentHeight: suggestion.map { CGFloat($0.count) * AtticDropdownMetrics.rowHeight + AtticDropdownMetrics.inset * 2 },
                       contentWidth: suggestion.map { AtticSuggestionList.idealWidth(items(for: $0)) }) {
            if let suggestion {
                AtticSuggestionList(items: items(for: suggestion), highlighted: min(title.highlighted, suggestion.count - 1),
                                    onHover: { index in if title.highlighted != index { title.highlighted = index } }) { index in
                    model.tasks.accept(suggestion, choice: index, editor: model.editor)
                    title.highlighted = 0
                }
            }
        }
    }

    @ViewBuilder
    private func mark(_ kind: ComposerKind) -> some View {
        let grey = TasksPanelDesign.toneInk(.meta, tokens: design.tokens).color
        switch kind {
        case .task:
            Circle().strokeBorder(grey, lineWidth: 0.9).frame(width: 12.7, height: 12.7)
        case .event:
            Circle().fill(model.selectedCalendar.map { Self.colour($0.colour) } ?? grey).frame(width: 7, height: 7)
        case .note:
            AtticIcon(systemName: "doc", size: 12, ink: .glyph).colour(TasksPanelDesign.toneInk(.meta, tokens: design.tokens))
        }
    }

    static func colour(_ colour: CalendarEventColour) -> Color {
        Color(.sRGB, red: colour.red, green: colour.green, blue: colour.blue, opacity: 1)
    }

    private var suggestion: TaskAddBarText.Suggestion? { model.suggestion(focused: titleFocused) }

    private var titleActions: AtticTokenFieldActions {
        let tasks = model.tasks
        return AtticTokenFieldActions(
            submit: { command in
                model.submit(openingPage: command)
                // The confirmed save clears the draft; native input must keep
                // it intact while an event write is still in flight.
            },
            dismissChip: { range in
                title.history.checkpoint(title.text, selection: title.currentSelection)
                title.text.dismiss(range)
            },
            // The card's title is one line; pasted lines join it.
            multilinePaste: { _ in false },
            escape: {
                guard open == nil else { open = nil; return true }
                model.close()
                return true
            },
            edited: { range, replacement in tasks.addBarEdited(range, replacement: replacement) },
            caretMoved: { caret in tasks.addBarCaretMoved(caret) },
            suggestionKey: { key in suggestionKey(key) },
            undoDraft: { title.undoDraft() },
            redoDraft: { title.redoDraft() },
            selectionMoved: { title.selection = $0 },
            undoFallback: { model.undoPage() },
            redoFallback: { model.redoPage() },
            tab: { _ in
                moveKeyboard(toWriting: true)
                return true
            }
        )
    }

    /// ↑ ↓ move, Tab or Return take the choice, Esc hides the list (the add
    /// bar's keys, kept).
    private func suggestionKey(_ key: AtticSuggestionKey) -> Bool {
        guard let suggestion else { return false }
        switch key {
        case .up, .down:
            title.highlighted = key == .up ? max(title.highlighted - 1, 0) : min(title.highlighted + 1, suggestion.count - 1)
        case .accept:
            model.tasks.accept(suggestion, choice: min(title.highlighted, suggestion.count - 1), editor: model.editor)
            title.highlighted = 0
        case .dismiss: title.hiddenSuggestion = suggestion.range
        }
        return true
    }

    private func items(for suggestion: TaskAddBarText.Suggestion) -> [AtticSuggestionList.Item] {
        switch suggestion {
        case let .tags(_, _, matches, create):
            return matches.map { AtticSuggestionList.Item(id: $0, title: "#" + $0) }
                + (create.map { [AtticSuggestionList.Item(id: "create-" + $0, title: String(localized: "Create #\($0)"), systemName: "plus")] } ?? [])
        case let .date(_, _, title, day):
            return [AtticSuggestionList.Item(id: day.rawValue, title: title, systemName: "calendar",
                                             detail: model.tasks.dateChoices.longDetail(for: day))]
        }
    }

    // MARK: Writing

    /// The writing, for every kind: a task's or note's writing, an event's
    /// notes.
    private func writingLine(_ kind: ComposerKind) -> some View {
        TextField(String(localized: "Notes"), text: $model.writing, axis: .vertical)
            .textFieldStyle(.plain)
            .font(AtticTextStyle.composerWriting.font)
            .foregroundStyle(TasksPanelDesign.toneInk(.nextEventTime, tokens: design.tokens).color)
            .lineLimit(1...ComposerMetrics.writingMaxLines)
            .frame(minHeight: ComposerMetrics.writingMinHeight, alignment: .topLeading)
            .focused($writingFocused)
            // The card's native Tab monitor moves forward through the actions
            // or backwards to Title before AppKit visits the panel underneath.
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.shift) && !press.modifiers.contains(.command) { return .ignored }
                model.submit(openingPage: press.modifiers.contains(.command))
                return .handled
            }
            .accessibilityIdentifier("composer-writing")
    }

    // MARK: Chips and Create

    @ViewBuilder
    private func actions(_ kind: ComposerKind) -> some View {
        if kind == .event { eventActions }
        else { standardActions(kind) }
    }

    private var eventActions: some View {
        VStack(alignment: .leading, spacing: ComposerMetrics.actionsTop) {
            dateChip(model.values, flex: true)
            if model.values.time != nil {
                chip(.length, systemName: "clock", label: Self.length(model.eventLength), set: true)
            }
            HStack(spacing: ComposerMetrics.chipGap) {
                calendarChip
                Spacer(minLength: 0)
                createButton
            }
        }
        .padding(.leading, ComposerMetrics.chipLeading)
    }

    /// The bottom row (Accepted 2026-11-04): the tag control sits in the
    /// same place in Task and Note, last before Create (as drawn in
    /// `composer-buttons-drafts.html`). Task: Date, then priority and tag;
    /// Note: Pin, then the tag. Each control hugs its own label, so a
    /// chosen priority and tag show on the card (#2) and Date's hover is
    /// only as wide as Date.
    private func standardActions(_ kind: ComposerKind) -> some View {
        let values = model.values
        let turns = PanelTakeTurns.transition(reduceMotion: design.reduceMotion)
        return HStack(spacing: ComposerMetrics.chipGap) {
            HStack(spacing: ComposerMetrics.chipGap) {
                switch kind {
                case .task:
                    if open == .priority {
                        priorityLevels
                            .transition(turns)
                    } else {
                        HStack(spacing: ComposerMetrics.chipGap) {
                            dateChip(values, flex: true)
                            Spacer(minLength: 0)
                            chip(.priority, systemName: "exclamationmark",
                                 label: values.priority.map(\.composerTitle) ?? String(localized: "Priority"),
                                 set: values.priority != nil, showsLabel: values.priority != nil,
                                 colour: values.priority == .high ? TasksPanelDesign.vivid(design.tokens.ink(.priorityHigh), tokens: design.tokens) : nil)
                                .fixedSize()
                            tagsChip(values, showsLabel: !values.tags.isEmpty)
                        }
                        .transition(turns)
                    }
                case .event:
                    EmptyView() // Event uses the taller rows above.
                case .note:
                    HStack(spacing: ComposerMetrics.chipGap) {
                        chip(.pin, systemName: "pin", label: model.pinned ? String(localized: "Pinned") : String(localized: "Pin"),
                             set: model.pinned).fixedSize()
                        Spacer(minLength: 0)
                        tagsChip(values, showsLabel: true)
                    }
                    .transition(turns)
                }
            }
            // Task ↔ Note: one row at a time, never both rows' words.
            .id(kind)
            .transition(turns)
            .padding(.leading, ComposerMetrics.chipLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
            createButton
        }
        // No I-beam over the row's buttons (#7): the text under the card
        // does not lend them its cursor.
        .pointerStyle(.default)
        .background(ComposerArrowCursor())
    }

    private var priorityLevels: some View {
        HStack(spacing: 1) {
            ForEach([TaskPriority.none, .low, .medium, .high], id: \.self) { priority in
                let selected = (pickedPriority ?? model.values.priority ?? .none) == priority
                Button {
                    priorityPickGeneration &+= 1
                    let generation = priorityPickGeneration
                    pickedPriority = priority
                    model.tasks.pickPriority(priority, editor: model.editor)
                    // The pick lights up, then the row closes.
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.pickedBeat) {
                        guard generation == priorityPickGeneration, open == .priority,
                              model.isOpen, model.kind == .task else { return }
                        open = nil
                        pickedPriority = nil
                    }
                } label: {
                    Text(priority == .none ? String(localized: "None") : priority.composerTitle)
                        .font(AtticTextStyle.composerChip.font)
                        .foregroundStyle(design.tokens.ink(.heading).color)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, minHeight: ComposerMetrics.chipHeight)
                        .background {
                            if selected {
                                AtticControlShape.shape(cornerRadius: ComposerMetrics.chipHeight / 2,
                                                        exponent: AtticShape.controlExponent)
                                    .fill(design.tokens.ink(.heading).withAlpha(0.06).color)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("composer-priority-\(priority)")
            }
        }
        .background(AtticControlShape.shape(cornerRadius: ComposerMetrics.chipHeight / 2,
                                             exponent: AtticShape.controlExponent)
            .fill(design.tokens.ink(.heading).withAlpha(0.035).color))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Priority"))
        .accessibilityAction(named: Text("Close Priority")) { open = nil }
    }

    /// How long a picked priority stays lit before its row closes.
    static let pickedBeat: TimeInterval = 0.15

    private func dateChip(_ values: ComposerModel.Values, flex: Bool) -> some View {
        chip(.date, systemName: "calendar", label: dateLabel(values), set: values.day != nil || model.kind == .event)
            .layoutPriority(-1)
    }

    private func tagsChip(_ values: ComposerModel.Values, showsLabel: Bool) -> some View {
        let tags = values.tags
        let label = tags.first.map { "#" + $0 + (tags.count > 1 ? " +\(tags.count - 1)" : "") } ?? String(localized: "Tags")
        let hue = tags.first.map { model.tasks.library.tagColours.palette.hue(for: $0) }
        return chip(.tags, systemName: "number", label: label, set: !tags.isEmpty, showsLabel: showsLabel,
                    colour: hue.map { TasksPanelDesign.tagInk($0, tokens: design.tokens) })
            .fixedSize()
    }

    private var calendarChip: some View {
        let calendar = model.selectedCalendar
        return chip(.calendar, systemName: nil, dot: calendar.map { Self.colour($0.colour) },
                    label: calendar?.title ?? String(localized: "Calendar"), set: calendar != nil)
    }

    func dateLabel(_ values: ComposerModel.Values) -> String {
        Self.dateLabel(values, kind: model.kind, words: { model.tasks.dueText($0) })
    }

    nonisolated static func dateLabel(_ values: ComposerModel.Values, kind: ComposerKind, words: (DueDay) -> String) -> String {
        let clock = values.time.map(Self.clock)
        switch kind {
        case .event:
            let day = values.day.map(words) ?? String(localized: "Today")
            return clock.map { "\(day), \($0)" } ?? String(localized: "\(day) · All day")
        default:
            guard let day = values.day else { return String(localized: "Date") }
            return clock.map { "\(words(day)), \($0)" } ?? words(day)
        }
    }

    nonisolated static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    nonisolated static func length(_ minutes: Int) -> String {
        if minutes < 60 { return String(localized: "\(minutes) min") }
        let rest = minutes % 60
        return rest == 0 ? String(localized: "\(minutes / 60) h") : String(localized: "\(minutes / 60) h \(rest)")
    }

    private func chip(_ id: Chip, systemName: String?, dot: Color? = nil, label: String, set: Bool,
                      showsLabel: Bool = true, colour: AtticRGBA? = nil) -> some View {
        let muted = TasksPanelDesign.toneInk(.meta, tokens: design.tokens)
        let heading = design.tokens.ink(.heading)
        return Button {
            if id == .pin { model.pinned.toggle(); return }
            open = open == id ? nil : id
        } label: {
            ComposerChipFace(open: open == id) { hovered in
                let ink = ComposerChipLook.ink(set: set, hovered: hovered, heading: heading, muted: muted)
                HStack(spacing: 3.5) {
                    if let systemName {
                        AtticIcon(systemName: systemName, size: ComposerMetrics.chipIcon, weight: .semibold, ink: .glyph).colour(ink)
                    } else if let dot {
                        Circle().fill(dot).frame(width: 6, height: 6).frame(width: ComposerMetrics.chipIcon)
                    }
                    if showsLabel {
                        AtticText(verbatim: label, style: .composerChip, ink: .body, truncates: true).colour(colour ?? ink)
                    }
                }
                .padding(.horizontal, ComposerMetrics.chipPadding)
                // Each chip hugs its icon and label: its hover is only as
                // wide as it (Accepted 2026-11-04: Date's stretched across
                // the row).
                .frame(minHeight: ComposerMetrics.chipHeight, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focusable(true)
        .focused($keyboardStop, equals: .chip(id))
        .overlay {
            if keyboardStop == .chip(id) {
                Squircle(cornerRadius: ComposerMetrics.chipHeight / 2, exponent: AtticShape.controlExponent)
                    .strokeBorder(design.tokens.ink(.heading).color.opacity(0.55), lineWidth: 1.2)
                    .allowsHitTesting(false)
            }
        }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier("composer-chip-\(id)")
    }

    @ViewBuilder
    private func picker(_ id: Chip) -> some View {
        let tasks = model.tasks
        let editor = model.editor
        switch id {
        case .date:
            TaskDatePickerView(choices: tasks.dateChoices, selected: model.values.day, onPick: { day in
                open = nil
                tasks.pickDate(day, editor: editor)
            }, onRemove: model.kind == .event ? nil : {
                open = nil
                tasks.clearComposer(.date, editor: editor)
            })
        case .priority:
            TaskPriorityPickerView(current: model.values.priority, onPick: { priority in
                open = nil
                tasks.pickPriority(priority, editor: editor)
            })
        case .tags:
            TaskTagPickerView(allTags: tasks.composerTagChoices, state: { tasks.composerTagState($0) },
                              onToggle: { tasks.toggleComposerTag($0, editor: editor) },
                              onCreate: { name, _ in tasks.toggleComposerTag(name, editor: editor); return true },
                              focusField: true)
        case .length:
            ComposerChoiceList(rows: ComposerModel.lengths.map { minutes in
                (id: "\(minutes)", title: Self.length(minutes), dot: nil, on: model.eventLength == minutes, pick: {
                    model.eventLength = minutes
                    open = nil
                })
            })
        case .calendar:
            ComposerChoiceList(rows: model.calendars.map { calendar in
                (id: calendar.id, title: calendar.title, dot: Self.colour(calendar.colour),
                 on: model.selectedCalendar?.id == calendar.id, pick: {
                    model.calendarID = calendar.id
                    open = nil
                })
            })
        case .pin:
            EmptyView()
        }
    }

    private var createButton: some View {
        let can = model.canCreate
        return Button { model.submit() } label: {
            AtticText(verbatim: String(localized: "Create"), style: .composerCreate, ink: .body)
                .colour(can ? design.tokens.ink(.onInverse) : AtticRGBA(red: 1, green: 1, blue: 1, alpha: 1))
                .padding(.horizontal, ComposerMetrics.createPadding)
                .frame(height: ComposerMetrics.createHeight)
                .background(
                    Squircle(cornerRadius: ComposerMetrics.createHeight / 2, exponent: AtticShape.controlExponent)
                        .fill(can ? design.tokens.ink(.inverseFill).color
                              : Color(.sRGB, red: 176 / 255, green: 178 / 255, blue: 182 / 255, opacity: 1))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focusable(true)
        .focused($keyboardStop, equals: .create)
        .overlay {
            if keyboardStop == .create {
                Squircle(cornerRadius: ComposerMetrics.createHeight / 2, exponent: AtticShape.controlExponent)
                    .strokeBorder(design.tokens.ink(.heading).color.opacity(0.65), lineWidth: 1.2)
                    .allowsHitTesting(false)
            }
        }
        .disabled(!can)
        .fixedSize()
        .accessibilityIdentifier("composer-create")
    }
}

/// The card's pickers (date, tags, an event's length and calendar): each
/// opens from the whole card, above it, so it never covers the card it
/// edits, and stays solid while it opens and goes (Accepted 2026-11-04,
/// #4 and #5).
private struct ComposerPickers<Picker: View>: ViewModifier {
    @Binding var open: ComposerCard.Chip?
    let label: String
    @ViewBuilder let picker: (ComposerCard.Chip) -> Picker

    func body(content: Content) -> some View {
        content
            .modifier(One(open: $open, chip: .date, label: label, picker: picker))
            .modifier(One(open: $open, chip: .tags, label: label, picker: picker))
            .modifier(One(open: $open, chip: .length, label: label, picker: picker))
            .modifier(One(open: $open, chip: .calendar, label: label, picker: picker))
    }

    private struct One: ViewModifier {
        @Binding var open: ComposerCard.Chip?
        let chip: ComposerCard.Chip
        let label: String
        let picker: (ComposerCard.Chip) -> Picker

        func body(content: Content) -> some View {
            content.atticDropdown(isPresented: Binding(get: { open == chip }, set: { if !$0, open == chip { open = nil } }),
                                  prefer: .above, label: label, opaqueMotion: true) {
                picker(chip)
            }
        }
    }
}

/// An arrow over the card's bottom row: a text view under the card must
/// not lend the row its I-beam (Accepted 2026-11-04, #7).
private struct ComposerArrowCursor: NSViewRepresentable {
    final class ArrowView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    }

    func makeNSView(context: Context) -> ArrowView {
        let view = ArrowView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: ArrowView, context: Context) {
        view.window?.invalidateCursorRects(for: view)
    }
}

/// A short list for the event's length and calendar, in the menus' rows.
private struct ComposerChoiceList: View {
    let rows: [(id: String, title: String, dot: Color?, on: Bool, pick: () -> Void)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows, id: \.id) { row in
                AtticChoiceRow(title: row.title, check: row.on ? .on : .off, action: row.pick)
                    .overlay(alignment: .leading) {
                        if let dot = row.dot { Circle().fill(dot).frame(width: 6, height: 6).padding(.leading, 2) }
                    }
            }
        }
        .padding(AtticDropdownMetrics.inset)
        .frame(minWidth: 140)
    }
}

extension TaskPriority {
    /// The Priority chip's word.
    var composerTitle: String {
        switch self {
        case .high: String(localized: "High")
        case .medium: String(localized: "Medium")
        case .low: String(localized: "Low")
        case .none: String(localized: "Priority")
        }
    }
}

/// Catches Tab and ⇧Tab in this view's window while `active` (the writing
/// line has the keyboard), before the field editor moves the keyboard out
/// of the card.
private struct ComposerTabTrap: NSViewRepresentable {
    let active: Bool
    let onTab: (Bool) -> Bool

    func makeNSView(context: Context) -> TrapView { TrapView() }

    func updateNSView(_ view: TrapView, context: Context) {
        view.onTab = onTab
        view.active = active
    }

    final class TrapView: NSView {
        var onTab: (Bool) -> Bool = { _ in false }
        private var monitor: Any?
        var active = false {
            didSet {
                guard active != oldValue else { return }
                if active {
                    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                        guard let self, event.keyCode == 48, event.window === self.window,
                              event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
                        return self.onTab(event.modifierFlags.contains(.shift)) ? nil : event
                    }
                } else if let monitor {
                    NSEvent.removeMonitor(monitor)
                    self.monitor = nil
                }
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { active = false }
        }
    }
}
