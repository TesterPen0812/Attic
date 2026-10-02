import SwiftUI

extension View {
    /// Applies a shortcut when there is one (Aa's toggles answer their keys
    /// while the pop-over has the keyboard).
    @ViewBuilder
    func noteShortcut(_ shortcut: KeyboardShortcut?) -> some View {
        if let shortcut { keyboardShortcut(shortcut) } else { self }
    }
}

/// The springy entrance the bar, Aa and the `/` list share: a fade, a 4 pt
/// rise and a slight grow from the anchored edge; a plain fade under
/// Reduce Motion.
enum NoteFormatMotion {
    static func transition(reduceMotion: Bool, from edge: VerticalEdge) -> AnyTransition {
        if reduceMotion { return .opacity }
        let rise = AtticMotionPreset.popover.rise
        return .opacity
            .combined(with: .offset(y: edge == .bottom ? rise : -rise))
            .combined(with: .scale(scale: 0.96, anchor: edge == .bottom ? .bottom : .top))
    }

    static func animation(reduceMotion: Bool) -> Animation? {
        AtticMotionPreset.popover.springy(reduceMotion: reduceMotion)
    }
}

// MARK: - Selection bar

/// The bar over a text selection (mockup p2-16 D): the style menu, B I U S,
/// link and highlight, bulleted list and checklist, each showing its state.
struct NoteFormatBarView: View {
    @ObservedObject var model: NoteFormatModel
    @Environment(\.atticDesign) private var design

    var body: some View {
        ZStack {
            if model.barShown {
                bar
                    .transition(NoteFormatMotion.transition(reduceMotion: design.reduceMotion,
                                                            from: model.barBelow ? .top : .bottom))
            }
        }
        .animation(NoteFormatMotion.animation(reduceMotion: design.reduceMotion), value: model.barShown)
        .padding(AtticNoteFormatMetrics.shadowRoom)
        .accessibilityHidden(!model.barShown)
    }

    private var bar: some View {
        let snapshot = model.snapshot
        let focus = model.barKeyboardIndex
        return AtticFormatBarSurface {
            AtticCommandMenu(commands: model.styleMenu(from: .selectionBar),
                             accessibilityLabel: String(localized: "Style, \(NoteCommandCatalog.styleName(snapshot.paragraph))")) {
                AtticFormatStyleFace(title: NoteCommandCatalog.styleName(snapshot.paragraph),
                                     isKeyboardFocused: focus == 0,
                                     isEnabled: NoteCommandCatalog.styles.contains { snapshot.isEnabled($0) })
            }
            .help(String(localized: "Style"))
            .accessibilityIdentifier("notes-format-bar-style")
            AtticFormatGroup { toggles(NoteCommandCatalog.barMarks, startingAt: 1) }
            AtticFormatGroup { toggles(NoteCommandCatalog.barInline, startingAt: 1 + NoteCommandCatalog.barMarks.count) }
            AtticFormatGroup {
                toggles(NoteCommandCatalog.barLists,
                        startingAt: 1 + NoteCommandCatalog.barMarks.count + NoteCommandCatalog.barInline.count)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Format bar"))
        .accessibilityIdentifier("notes-format-bar")
    }

    private func toggles(_ commands: [NoteFormatCommand], startingAt start: Int) -> some View {
        ForEach(Array(commands.enumerated()), id: \.offset) { offset, command in
            NoteFormatToggle(model: model, command: command, surface: .selectionBar,
                             width: AtticNoteFormatMetrics.barToggleWidth,
                             isKeyboardFocused: model.barKeyboardIndex == start + offset)
        }
    }
}

/// One command as a toggle, from the snapshot.
struct NoteFormatToggle: View {
    @ObservedObject var model: NoteFormatModel
    let command: NoteFormatCommand
    let surface: NoteCommandSurface
    let width: CGFloat
    var isKeyboardFocused = false

    var body: some View {
        let snapshot = model.snapshot
        let label = NoteCommandCatalog.menuTitle(command).replacingOccurrences(of: "…", with: "")
        Group {
            if command == .mark(.highlight) {
                AtticFormatToggle(value: snapshot.value(command), label: label, help: NoteFormatModel.help(command),
                                  width: width, isKeyboardFocused: isKeyboardFocused,
                                  disabledReason: snapshot.disabledReason, action: run) { ink in
                    AtticHighlightGlyph(ink: ink, swatch: model.highlightSwatch)
                }
            } else {
                AtticFormatToggle(systemName: NoteCommandCatalog.symbol(command), value: snapshot.value(command),
                                  label: label, help: NoteFormatModel.help(command), width: width,
                                  isKeyboardFocused: isKeyboardFocused, disabledReason: snapshot.disabledReason,
                                  action: run)
            }
        }
        .disabled(!snapshot.isEnabled(command))
        .accessibilityIdentifier(NoteCommandRouter.identifier(command))
    }

    private func run() { model.run(command, from: surface) }
}

// MARK: - Aa

/// Aa's pop-over (mockup p2-16 B and D): every style and format, working
/// on the selection or the caret's paragraph. ← → ↑ ↓ move, Return or
/// Space press, Esc closes; each toggle also answers its own shortcut.
struct NoteFormatPopoverView: View {
    @ObservedObject var model: NoteFormatModel
    /// Opened from the keyboard (⌘T, ⌃Tab): the ring shows at once.
    var openedByKeyboard = false
    let onClose: () -> Void

    @Environment(\.atticDesign) private var design
    @FocusState private var focused: Bool

    var body: some View {
        let m = AtticNoteFormatMetrics.self
        let snapshot = model.snapshot
        VStack(alignment: .leading, spacing: m.popoverRowGap) {
            HStack(spacing: 2) {
                ForEach(Array(NoteCommandCatalog.styles.enumerated()), id: \.offset) { column, command in
                    AtticFormatStyleChip(kind: chipKind(command), title: command.title,
                                         isOn: snapshot.value(command) == .on,
                                         isKeyboardFocused: isFocused(row: 0, column: column),
                                         disabledReason: snapshot.disabledReason) {
                        model.run(command, from: .formatPopover)
                    }
                    .disabled(!snapshot.isEnabled(command))
                    .noteShortcut(NoteCommandCatalog.keyboardShortcut(command))
                    .help(NoteFormatModel.help(command))
                    .accessibilityIdentifier("notes-aa-" + NoteCommandRouter.identifier(command))
                }
            }
            row(1, groups: [NoteCommandCatalog.marks, NoteCommandCatalog.inline])
            row(2, groups: [NoteCommandCatalog.lists, NoteCommandCatalog.indents])
            if let reason = snapshot.disabledReason {
                AtticText(verbatim: reason, style: .helper, ink: .helper)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("notes-aa-reason")
            }
        }
        // The dropdown card's inset is Aa's padding.
        .frame(width: m.popoverWidth - AtticDropdownMetrics.inset * 2)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .atticDropdownFocus($focused)
        .onAppear {
            model.popoverKeyboardIndex = openedByKeyboard ? currentStyleIndex : nil
        }
        .onDisappear { model.popoverKeyboardIndex = nil }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .tab]) { press in
            let start = model.popoverKeyboardIndex ?? currentStyleIndex
            if model.popoverKeyboardIndex == nil {
                model.popoverKeyboardIndex = start
                return .handled
            }
            let key: KeyEquivalent = press.key == .tab
                ? (press.modifiers.contains(.shift) ? .leftArrow : .rightArrow) : press.key
            model.popoverKeyboardIndex = NoteFormatPopoverGrid.move(start, by: key)
            return .handled
        }
        .onKeyPress(keys: [.return, .space]) { _ in
            guard let index = model.popoverKeyboardIndex, let command = NoteFormatPopoverGrid.command(at: index),
                  snapshot.isEnabled(command) else { return .ignored }
            model.run(command, from: .formatPopover)
            return .handled
        }
        .onKeyPress(.escape) {
            // Used up here: Esc closes Aa and nothing behind it.
            onClose()
            return .handled
        }
        .onExitCommand { onClose() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Format"))
        .accessibilityIdentifier("notes-format-popover")
    }

    private var currentStyleIndex: NoteGridIndex {
        let column = NoteCommandCatalog.styles.firstIndex { model.snapshot.value($0) == .on } ?? 3
        return NoteGridIndex(row: 0, column: column)
    }

    private func isFocused(row: Int, column: Int) -> Bool {
        model.popoverKeyboardIndex == NoteGridIndex(row: row, column: column)
    }

    private func row(_ row: Int, groups: [[NoteFormatCommand]]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
                if groupIndex > 0 { Spacer(minLength: AtticNoteFormatMetrics.popoverGroupGap) }
                let start = groups.prefix(groupIndex).reduce(0) { $0 + $1.count }
                AtticFormatGroup {
                    ForEach(Array(group.enumerated()), id: \.offset) { offset, command in
                        NoteFormatToggle(model: model, command: command, surface: .formatPopover,
                                         width: AtticNoteFormatMetrics.popoverToggleWidth,
                                         isKeyboardFocused: isFocused(row: row, column: start + offset))
                            .noteShortcut(NoteCommandCatalog.keyboardShortcut(command))
                    }
                }
            }
        }
    }

    private func chipKind(_ command: NoteFormatCommand) -> AtticFormatStyleChip.Kind {
        switch command {
        case .paragraph(.heading(1)): .title
        case .paragraph(.heading(2)): .heading
        case .paragraph(.heading): .subheading
        case .paragraph(.mono): .mono
        default: .body
        }
    }
}

// MARK: - The / list

/// The flat `/` list at the caret (p2-03; E1, p2-24 D): one row per
/// engine item, icon and name only (no hint column), the typed filter
/// emboldened. The keyboard and the pointer move the one highlight. It
/// opens below the caret when there is room, its left edge on the `/`.
struct NoteSlashListView: View {
    @ObservedObject var model: NoteSlashListModel
    @Environment(\.atticDesign) private var design

    var body: some View {
        let preset = AtticMotionPreset.popover
        ZStack(alignment: model.above ? .bottomLeading : .topLeading) {
            if model.shown, !model.items.isEmpty {
                AtticDropdownCard(width: model.width) {
                    rows
                }
                .environment(\.atticDropdownHeight, model.viewportHeight)
                .transition(preset.transition(reduceMotion: design.reduceMotion, edge: model.above ? .bottom : .top,
                                              anchor: model.above ? .bottomLeading : .topLeading))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(String(localized: "Insert"))
                .accessibilityIdentifier("notes-slash-list")
            }
        }
        .animation(preset.animation(reduceMotion: design.reduceMotion, showing: model.shown), value: model.shown)
        .padding(AtticDropdownMetrics.shadowRoom)
        .fixedSize()
    }
}

extension NoteSlashListView {
    @ViewBuilder
    fileprivate var rows: some View {
        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
            AtticDropdownRow(title: item.title, systemName: NoteCommandCatalog.slashSymbol(item.kind), match: model.query,
                             isHighlighted: index == model.highlighted,
                             onHover: { inside in
                                 // The list always keeps one highlight (Return takes it).
                                 if inside, model.highlighted != index { model.highlighted = index }
                             }, position: index + 1, itemCount: model.items.count) {
                model.onPick?(item.kind)
            }
            .id(index)
            .accessibilityIdentifier("notes-slash-\(item.kind.rawValue)")
        }
    }
}

// MARK: - Date and link cards

/// The date card (p2-03 #3): type a date ("fri"); Return inserts the
/// match (today when nothing is typed); a day in the month inserts it; Esc
/// puts the typed `/date` back.
struct NoteDateCardView: View {
    @ObservedObject var model: NoteFormatCardModel
    @FocusState private var fieldFocused: Bool
    @Environment(\.atticDesign) private var design

    var body: some View {
        let candidate = model.candidateDate
        AtticDropdownCard {
            AtticDropdownField(text: $model.dateText, placeholder: String(localized: "Type a date, like fri"),
                               focus: $fieldFocused, label: String(localized: "Date"), identifier: "notes-date-field",
                               onSubmit: { if let candidate { model.onCommitDate?(candidate) } })
                .onExitCommand { model.onCancel?() }
            AtticDropdownGap()
            if let candidate {
                AtticDropdownRow(title: candidate.formatted(.dateTime.weekday(.wide)),
                                 detail: candidate.formatted(.dateTime.day().month(.abbreviated)),
                                 isHighlighted: true, position: 1, itemCount: 1) { model.onCommitDate?(candidate) }
                    .accessibilityIdentifier("notes-date-suggestion")
            } else {
                AtticText(verbatim: String(localized: "No date matches"), style: .dropdownRow, ink: .helper)
                    .padding(.horizontal, AtticDropdownMetrics.rowPadding)
                    .frame(height: AtticDropdownMetrics.rowHeight)
            }
            AtticDropdownGap(height: AtticDropdownMetrics.fieldGap)
            AtticDateCalendar(month: model.dateMonth, today: model.today, selected: candidate, calendar: model.calendar,
                              onPick: { model.onCommitDate?($0) },
                              onMonth: { delta in
                                  model.dateMonth = model.calendar.date(byAdding: .month, value: delta, to: model.dateMonth) ?? model.dateMonth
                              })
        }
        .onAppear { fieldFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Insert date"))
        .accessibilityIdentifier("notes-date-card")
    }
}

/// The link card (⇧⌘K, the link toggle, Edit Link…): the address and,
/// for an existing link, Remove. Return applies; Esc cancels.
struct NoteLinkCardView: View {
    @ObservedObject var model: NoteFormatCardModel
    let hasLink: Bool
    @FocusState private var fieldFocused: Bool
    @Environment(\.atticDesign) private var design

    var body: some View {
        AtticDropdownCard(width: AtticNoteFormatMetrics.linkCardWidth) {
            AtticDropdownField(text: $model.linkText, placeholder: String(localized: "Paste or type a link"),
                               focus: $fieldFocused, label: String(localized: "Link address"), identifier: "notes-link-field",
                               onSubmit: { model.submitLink() })
                .onExitCommand { model.onCancel?() }
            if let error = model.linkError {
                AtticText(verbatim: error, style: .helper, ink: .helper)
                    .padding(.horizontal, AtticDropdownMetrics.rowPadding)
                    .padding(.top, 4)
            }
            AtticDropdownGap()
            HStack(spacing: 4) {
                if hasLink {
                    AtticSmallButton(systemName: nil, title: "Remove", label: "Remove Link") { model.onRemoveLink?() }
                        .accessibilityIdentifier("notes-link-remove")
                }
                Spacer(minLength: 0)
                AtticSmallButton(systemName: nil, title: hasLink ? "Update" : "Add Link",
                                 label: hasLink ? "Update Link" : "Add Link") { model.submitLink() }
                    .disabled(model.linkText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("notes-link-apply")
            }
        }
        .onAppear { fieldFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Link"))
        .accessibilityIdentifier("notes-link-card")
    }
}

/// The card on screen, if any, with the shared motion.
struct NoteFormatCardView: View {
    @ObservedObject var model: NoteFormatCardModel
    @Environment(\.atticDesign) private var design

    var body: some View {
        let preset = AtticMotionPreset.popover
        let transition = preset.transition(reduceMotion: design.reduceMotion, edge: model.above ? .bottom : .top,
                                           anchor: model.above ? .bottomLeading : .topLeading)
        ZStack(alignment: model.above ? .bottomLeading : .topLeading) {
            switch model.card {
            case .date:
                NoteDateCardView(model: model).environment(\.atticDropdownHeight, model.viewportHeight).transition(transition)
            case let .link(hasLink):
                NoteLinkCardView(model: model, hasLink: hasLink).environment(\.atticDropdownHeight, model.viewportHeight).transition(transition)
            case nil:
                EmptyView()
            }
        }
        .animation(preset.animation(reduceMotion: design.reduceMotion, showing: model.card != nil), value: model.card)
        .padding(AtticDropdownMetrics.shadowRoom)
        .fixedSize()
    }
}

/// "Type / for lists, checklists and more" on a new draft's empty body line
/// (the first three drafts).
struct NoteSlashHintView: View {
    var body: some View {
        AtticText(verbatim: String(localized: "Type / for lists, checklists and more"), style: .noteBody, ink: .placeholder)
            .fixedSize()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
