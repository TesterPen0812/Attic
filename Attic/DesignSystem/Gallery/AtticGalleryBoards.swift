#if DEBUG
import SwiftUI

// The component gallery's boards: every component in every state, grouped
// by family. Preview builds only (compiled out of Release). Each board is
// drawn on its family's stage (the panel surface, or the Settings window)
// in whatever design context the gallery or the check applies.

enum AtticGalleryFamily: String, CaseIterable, Identifiable, Sendable {
    case panel
    case raisedControls
    case pageSwitch
    case addBar
    case smallControls
    case statusCircle
    case taskRows
    case quickLook
    case tags
    case feedback
    case focusAndSelection
    case edgeBlur
    case dragAndDrop
    case settings
    case tokens

    var id: String { rawValue }

    var title: String {
        switch self {
        case .panel: "Panel"
        case .raisedControls: "Raised controls"
        case .pageSwitch: "Page switch"
        case .addBar: "Add bar"
        case .smallControls: "Small controls and menus"
        case .statusCircle: "Status circle"
        case .taskRows: "Task rows"
        case .quickLook: "Quick look and task card"
        case .tags: "Tags"
        case .feedback: "Toast, empty, error, loading"
        case .focusAndSelection: "Focus, hover and selection"
        case .edgeBlur: "Edge blur"
        case .dragAndDrop: "Drag and drop"
        case .settings: "Settings"
        case .tokens: "Tokens"
        }
    }

    enum Stage { case panel, settingsWindow }

    var stage: Stage { self == .settings ? .settingsWindow : .panel }

    /// The board's width; boards grow to fit their height.
    var width: CGFloat {
        switch self {
        case .settings: 760
        case .tokens: 360
        default: AtticLayout.panelSize.width
        }
    }
}

/// Live demo state for the interactive specimens (static in captures).
@Observable
final class AtticGalleryDemo {
    var page = 0
    var tab = 0
    var addText = ""
    var addTextFilled = "Call the printer #office fri"
    var liveState: AtticTaskState = .todo
    var expandedRow = true
    var expandedCard = true
    var toastShown = true
    var surface = 0
    var tint = 2
    var haptics = true
    var dropPhase = 0
}

/// A captioned specimen. The caption is gallery chrome, not a component.
struct AtticSpecimen<Content: View>: View {
    let title: String
    var fullWidth = false
    @ViewBuilder let content: Content

    @Environment(\.atticDesign) private var design
    @Environment(\.atticSpecimen) private var board
    @State private var probeID = UUID()

    init(_ title: String, fullWidth: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.fullWidth = fullWidth
        self.content = content()
    }

    var body: some View {
        // Unique per specimen, even when two share a caption.
        let key = (board.isEmpty ? title : "\(board) / \(title)") + "#" + probeID.uuidString.prefix(8)
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(design.tokens.color(.helper))
                .lineLimit(1)
                .padding(.leading, fullWidth ? 16 : 0)
            content
                .environment(\.atticSpecimen, key)
        }
        .atticProbe { [probeID] _ in AtticProbe(id: probeID, kind: .specimen, specimen: key) }
    }
}

/// A row of specimens, wrapping by hand (boards are narrow).
private struct SpecimenRow<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(alignment: .top, spacing: 16) { content }
            .padding(.horizontal, 16)
    }
}

/// A board section heading (gallery chrome).
private struct BoardHeading: View {
    let title: String
    @Environment(\.atticDesign) private var design

    var body: some View {
        Text(verbatim: title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(design.tokens.color(.label))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 16)
            .padding(.top, 8)
    }
}

// MARK: - Sample data

enum AtticGallerySamples {
    static let rows: [AtticTaskRowModel] = [
        .init(title: "Finalize launch checklist", state: .inProgress, priority: .high,
              due: .init(text: "Today", isUrgent: true), tags: ["launch"], attachments: 2, subtasks: (1, 3)),
        .init(title: "Ship appearance PR", state: .todo, priority: .high, subtasks: (2, 4)),
        .init(title: "Email beta testers", state: .todo, priority: .medium, due: .init(text: "Fri", isUrgent: false)),
        .init(title: "Book dentist", state: .todo, priority: .none, due: .init(text: "Tomorrow", isUrgent: false)),
        .init(title: "Renew domain", state: .done, priority: .low)
    ]

    static let subtasks: [AtticSubtaskModel] = [
        .init(title: "Freeze strings", isDone: true),
        .init(title: "Write release notes"),
        .init(title: "Tag the build")
    ]

    static let pages: [AtticPageSwitch<Int>.Item] = [
        .init(page: 0, systemName: "checkmark.circle", title: String(localized: "Tasks"), shortcut: "⌘1"),
        .init(page: 1, systemName: "note.text", title: String(localized: "Notes"), shortcut: "⌘2"),
        .init(page: 2, systemName: "scribble.variable", title: String(localized: "Canvas"), shortcut: "⌘3")
    ]

    static let tabs: [AtticStatusTabs<Int>.Item] = [
        .init(tab: 0, title: String(localized: "Now"), count: 4),
        .init(tab: 1, title: String(localized: "Backlog"), count: 3),
        .init(tab: 2, title: String(localized: "Done"), count: nil)
    ]
}

// MARK: - Boards

struct AtticGalleryBoard: View {
    let family: AtticGalleryFamily
    @Bindable var demo: AtticGalleryDemo

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch family {
            case .panel: PanelBoard(demo: demo)
            case .raisedControls: RaisedControlsBoard()
            case .pageSwitch: PageSwitchBoard(demo: demo)
            case .addBar: AddBarBoard(demo: demo)
            case .smallControls: SmallControlsBoard()
            case .statusCircle: StatusCircleBoard(demo: demo)
            case .taskRows: TaskRowsBoard()
            case .quickLook: QuickLookBoard(demo: demo)
            case .tags: TagsBoard()
            case .feedback: FeedbackBoard(demo: demo)
            case .focusAndSelection: FocusBoard()
            case .edgeBlur: EdgeBlurBoard()
            case .dragAndDrop: DragBoard(demo: demo)
            case .settings: SettingsBoard(demo: demo)
            case .tokens: TokensBoard()
            }
        }
        .padding(.vertical, family == .panel || family == .settings ? 0 : 16)
        .frame(width: family.width, alignment: .topLeading)
        .environment(\.atticSpecimen, family.title)
    }
}

// MARK: Panel composition

/// The whole panel, composed from the components, at its default size.
private struct PanelBoard: View {
    @Bindable var demo: AtticGalleryDemo

    var body: some View {
        AtticSpecimen("Panel · 320 × 520, corner size 52", fullWidth: true) {
            AtticGalleryPanelComposition(demo: demo)
        }
    }
}

struct AtticGalleryPanelComposition: View {
    @Bindable var demo: AtticGalleryDemo
    var rows: [AtticTaskRowModel] = AtticGallerySamples.rows
    var selectedIndex: Int? = 1

    var body: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: AtticSpacing.panelMargin + AtticControlSize.capsuleHeight + AtticLayout.statusTabsTop)
                AtticStatusTabs(items: AtticGallerySamples.tabs, selection: $demo.tab)
                    .padding(.leading, AtticLayout.circleX)
                Color.clear.frame(height: AtticLayout.statusTabsToList)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    AtticTaskRow(model: row, isSelected: index == selectedIndex)
                }
                AtticEmptyLine(text: String(localized: "Done tasks move to Done tomorrow"))
                Spacer(minLength: 0)
            }
            VStack(spacing: 0) {
                AtticEdgeVeil(edge: .top, height: AtticEdgeBlur.panelTop)
                Spacer(minLength: 0)
                AtticEdgeVeil(edge: .bottom, height: AtticEdgeBlur.panelBottom)
            }
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    AtticRaisedButton(systemName: "pin", label: "Pin", help: "Pin (⇧⌘P)") {}
                    Spacer(minLength: AtticSpacing.betweenControls)
                    AtticPageSwitch(items: AtticGallerySamples.pages, selection: $demo.page)
                }
                Spacer(minLength: 0)
                AtticAddBar(placeholder: "Add a task…", text: $demo.addText)
            }
            .padding(AtticSpacing.panelMargin)
        }
        .frame(width: AtticLayout.panelSize.width, height: AtticLayout.panelSize.height)
        .background(AtticPanelStageSurface(cornerSize: 52))
        .clipShape(Squircle(cornerRadius: 52, exponent: AtticStyle.panelSquircleExponent))
        .overlay(AtticPanelRim(cornerSize: 52))
    }
}

/// The panel's own surface inside its squircle (the gallery draws the
/// Phase 1 default corner, 52).
struct AtticPanelStageSurface: View {
    var cornerSize: CGFloat
    @Environment(\.atticDesign) private var design

    var body: some View {
        AtticSurfaceBackground(model: design.tokens.panel, shape: Squircle(cornerRadius: cornerSize, exponent: AtticStyle.panelSquircleExponent))
    }
}

struct AtticPanelRim: View {
    var cornerSize: CGFloat
    @Environment(\.atticDesign) private var design

    var body: some View {
        let shape = Squircle(cornerRadius: cornerSize, exponent: AtticStyle.panelSquircleExponent)
        let dark = design.mode == .dark
        ZStack {
            shape.stroke(dark ? Color.black.opacity(0.5) : Color.black.opacity(design.increaseContrast ? 0.3 : 0.10), lineWidth: design.increaseContrast ? 1 : 0.5)
            if dark {
                Squircle(cornerRadius: cornerSize - 0.75, exponent: AtticStyle.panelSquircleExponent)
                    .stroke(Color.white.opacity(design.increaseContrast ? 0.3 : 0.08), lineWidth: 0.5)
                    .padding(0.75)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: Raised controls

private struct RaisedControlsBoard: View {
    var body: some View {
        BoardHeading(title: "Single button · 36 × 32, radius 10")
        SpecimenRow {
            ForEach([AtticControlState.rest, .hover, .pressed], id: \.self) { state in
                AtticSpecimen(state.title) {
                    AtticRaisedButton(systemName: "pin", label: "Pin") {}.atticForcedState(state)
                }
            }
        }
        SpecimenRow {
            ForEach([AtticControlState.focused, .disabled], id: \.self) { state in
                AtticSpecimen(state.title) {
                    AtticRaisedButton(systemName: "pin", label: "Pin") {}.atticForcedState(state)
                }
            }
            AtticSpecimen("Pinned") {
                AtticRaisedButton(systemName: "pin.fill", label: "Unpin") {}
            }
        }
        BoardHeading(title: "Label buttons · 32 tall")
        SpecimenRow {
            AtticSpecimen("All notes") {
                AtticRaisedButton(systemName: "list.bullet", title: "All notes") {}
            }
            AtticSpecimen("New note, hover") {
                AtticRaisedButton(systemName: "square.and.pencil", title: "New note") {}.atticForcedState(.hover)
            }
        }
        BoardHeading(title: "Settings back button · 38 × 34, radius 11")
        SpecimenRow {
            ForEach([AtticControlState.rest, .hover, .pressed, .focused], id: \.self) { state in
                AtticSpecimen(state.title) {
                    AtticRaisedButton(systemName: "chevron.left", label: "Back", size: AtticControlSize.settingsBackButton) {}
                        .atticForcedState(state)
                }
            }
        }
    }
}

// MARK: Page switch

private struct PageSwitchBoard: View {
    @Bindable var demo: AtticGalleryDemo

    var body: some View {
        BoardHeading(title: "Group capsule · 32 tall, chips 24, radius 6, inset 4")
        ForEach(0..<3, id: \.self) { page in
            SpecimenRow {
                AtticSpecimen(["Tasks selected", "Notes selected", "Canvas selected"][page]) {
                    AtticPageSwitch(items: AtticGallerySamples.pages, selection: .constant(page))
                }
            }
        }
        SpecimenRow {
            AtticSpecimen("Live (click, or ⌘1–⌘3 in Phase 1)") {
                AtticPageSwitch(items: AtticGallerySamples.pages, selection: $demo.page)
            }
        }
        SpecimenRow {
            AtticSpecimen("Hover on Notes") {
                AtticPageSwitch(items: AtticGallerySamples.pages, selection: .constant(0), statePinnedPage: 1).atticForcedState(.hover)
            }
        }
        SpecimenRow {
            AtticSpecimen("Keyboard focus on Canvas") {
                AtticPageSwitch(items: AtticGallerySamples.pages, selection: .constant(0), statePinnedPage: 2).atticForcedState(.focused)
            }
        }
        BoardHeading(title: "Status tabs · 13 pt, 14 apart, no underline")
        SpecimenRow {
            AtticSpecimen("Now selected") {
                AtticStatusTabs(items: AtticGallerySamples.tabs, selection: .constant(0))
            }
        }
        SpecimenRow {
            AtticSpecimen("Backlog selected, hover on Done") {
                AtticStatusTabs(items: AtticGallerySamples.tabs, selection: .constant(1), statePinnedTab: 2).atticForcedState(.hover)
            }
        }
    }
}

// MARK: Add bar

private struct AddBarBoard: View {
    @Bindable var demo: AtticGalleryDemo

    var body: some View {
        BoardHeading(title: "Add bar · 36 tall, radius 11.5; send appears with text")
        Group {
            AtticSpecimen("Empty", fullWidth: true) {
                AtticAddBar(placeholder: "Add a task…", text: .constant("")).padding(.horizontal, 12)
            }
            AtticSpecimen("Hover: no fill; the cursor becomes the I-beam", fullWidth: true) {
                AtticAddBar(placeholder: "Add a task…", text: .constant("")).padding(.horizontal, 12).atticForcedState(.hover)
            }
            AtticSpecimen("With text: send button inside", fullWidth: true) {
                AtticAddBar(placeholder: "Add a task…", text: .constant(demo.addTextFilled)).padding(.horizontal, 12)
            }
            AtticSpecimen("Backlog page", fullWidth: true) {
                AtticAddBar(placeholder: "Add to backlog…", text: .constant("")).padding(.horizontal, 12)
            }
            AtticSpecimen("Keyboard focus", fullWidth: true) {
                AtticAddBar(placeholder: "Add a task…", text: .constant("")).padding(.horizontal, 12).atticForcedState(.focused)
            }
            AtticSpecimen("Live (type to see the send button)", fullWidth: true) {
                AtticAddBar(placeholder: "Add a task…", text: $demo.addText) { demo.addText = "" }.padding(.horizontal, 12)
            }
        }
    }
}

// MARK: Small controls and menus

private struct SmallControlsBoard: View {
    var body: some View {
        BoardHeading(title: "Selection bar · small controls 28 tall, radius 9")
        AtticSpecimen("Selection bar", fullWidth: true) {
            AtticSelectionBar(count: 3, actions: [
                .init(systemName: "circle.dashed", label: "State") {},
                .init(systemName: "flag", label: "Priority") {},
                .init(systemName: "number", label: "Tag") {},
                .init(systemName: "arrow.right.square", label: "Move") {},
                .init(systemName: "trash", label: "Delete") {}
            ])
            .padding(.horizontal, 16)
        }
        SpecimenRow {
            ForEach([AtticControlState.rest, .hover, .pressed, .focused, .disabled], id: \.self) { state in
                AtticSpecimen(state == .focused ? "Focus" : state.title) {
                    AtticSmallButton(systemName: "flag", label: "Priority") {}.atticForcedState(state)
                }
            }
        }
        BoardHeading(title: "Menu · radius 20; rows 28, radius 9")
        SpecimenRow {
            AtticSpecimen("Title pop-over menu") {
                AtticMenu(width: 236) {
                    AtticMenuRow(systemName: "macwindow", title: "Open in window", shortcut: "⇧⌘O") {}
                        .atticForcedState(.hover)
                    AtticMenuRow(systemName: "plus.square.on.square", title: "Duplicate", shortcut: "⌘D") {}
                    AtticMenuRow(systemName: "square.and.arrow.up", title: "Export…") {}
                        .disabled(true)
                    AtticMenuGap()
                    AtticMenuRow(systemName: "trash", title: "Delete", shortcut: "⌫") {}
                }
            }
        }
    }
}

// MARK: Status circle

private struct StatusCircleBoard: View {
    @Bindable var demo: AtticGalleryDemo

    var body: some View {
        BoardHeading(title: "States × priorities · 16 pt")
        VStack(alignment: .leading, spacing: 10) {
            ForEach(AtticTaskState.allCases, id: \.self) { state in
                AtticSpecimen(stateTitle(state), fullWidth: true) {
                    HStack(spacing: 22) {
                        ForEach(AtticPriority.allCases, id: \.self) { priority in
                            VStack(spacing: 4) {
                                AtticStatusCircle(state: state, priority: priority)
                                AtticText(verbatim: priority.rawValue.capitalized, style: .rowMeta, ink: .helper)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        BoardHeading(title: "Completion · fill fades in, check draws (200 ms)")
        AtticSpecimen("Frames: 0, 35, 70, 100 %", fullWidth: true) {
            HStack(spacing: 22) {
                ForEach([0.0, 0.35, 0.7, 1.0], id: \.self) { progress in
                    AtticStatusCircle(state: .done, priority: .high, checkProgress: progress)
                        .opacity(progress == 0 ? 0.25 : min(1, 0.4 + progress))
                }
            }
            .padding(.horizontal, 16)
        }
        AtticSpecimen("Live: click the circle to advance", fullWidth: true) {
            HStack(spacing: 10) {
                AtticStatusButton(state: demo.liveState, priority: .medium) {
                    demo.liveState = switch demo.liveState {
                    case .todo: .inProgress
                    case .inProgress: .done
                    case .done: .todo
                    case .backlog: .todo
                    }
                }
                AtticText(verbatim: demo.liveState.spokenName.prefix(1).uppercased() + demo.liveState.spokenName.dropFirst(), style: .rowMeta, ink: .helper)
            }
            .padding(.horizontal, 10)
        }
        AtticSpecimen("Differentiate Without Colour mark", fullWidth: true) {
            HStack(spacing: 22) {
                ForEach(AtticPriority.allCases, id: \.self) { priority in
                    AtticStatusCircle(state: .todo, priority: priority)
                }
            }
            .padding(.horizontal, 16)
            .transformEnvironment(\.atticDesign) { $0.differentiateWithoutColor = true }
        }
    }

    private func stateTitle(_ state: AtticTaskState) -> String {
        switch state {
        case .todo: "To do: ring in the priority colour"
        case .inProgress: "In progress: half filled"
        case .done: "Done: filled, with a check"
        case .backlog: "Backlog: dashed ring"
        }
    }
}

// MARK: Task rows

private struct TaskRowsBoard: View {
    var body: some View {
        let rows = AtticGallerySamples.rows
        BoardHeading(title: "32 pt; 44 pt with a details line")
        AtticSpecimen("Rest", fullWidth: true) { AtticTaskRow(model: rows[2]) }
        AtticSpecimen("Details line: today, tag, files", fullWidth: true) { AtticTaskRow(model: rows[0]) }
        AtticSpecimen("Hover", fullWidth: true) { AtticTaskRow(model: rows[1]).atticForcedState(.hover) }
        AtticSpecimen("Selected", fullWidth: true) { AtticTaskRow(model: rows[1], isSelected: true) }
        AtticSpecimen("Pressed", fullWidth: true) { AtticTaskRow(model: rows[1]).atticForcedState(.pressed) }
        AtticSpecimen("Keyboard focus", fullWidth: true) { AtticTaskRow(model: rows[3]).atticForcedState(.focused) }
        AtticSpecimen("Disabled (while saving)", fullWidth: true) { AtticTaskRow(model: rows[3]).atticForcedState(.disabled) }
        AtticSpecimen("Done: struck through, faded", fullWidth: true) { AtticTaskRow(model: rows[4]) }
        AtticSpecimen("Backlog", fullWidth: true) {
            AtticTaskRow(model: .init(title: "Plan Friday retro", state: .backlog, priority: .low))
        }
        AtticSpecimen("Touching selected rows merge", fullWidth: true) {
            VStack(spacing: 0) {
                AtticTaskRow(model: rows[1], isSelected: true, selectionRun: .first)
                AtticTaskRow(model: rows[2], isSelected: true, selectionRun: .middle)
                AtticTaskRow(model: rows[3], isSelected: true, selectionRun: .last)
            }
        }
        AtticSpecimen("In a window; links", fullWidth: true) {
            AtticTaskRow(model: .init(title: "Draft the pricing page", priority: .medium, links: 2, inWindow: true))
        }
        AtticSpecimen("A very long title truncates, never wraps", fullWidth: true) {
            AtticTaskRow(model: .init(title: "Write the long overdue follow-up to everyone who replied to the beta invite", subtasks: (0, 5)))
        }
    }
}

// MARK: Quick look and cards

private struct QuickLookBoard: View {
    @Bindable var demo: AtticGalleryDemo

    var body: some View {
        BoardHeading(title: "Quick look · the row expands in place")
        AtticSpecimen("Expanded", fullWidth: true) {
            VStack(spacing: 0) {
                AtticTaskRow(model: AtticGallerySamples.rows[0], isSelected: true, isExpanded: true)
                AtticQuickLook(subtasks: AtticGallerySamples.subtasks)
            }
        }
        AtticSpecimen("Live: click the count", fullWidth: true) {
            VStack(spacing: 0) {
                AtticTaskRow(model: AtticGallerySamples.rows[1], isExpanded: demo.expandedRow, onToggleExpanded: {
                    withAnimation(AtticMotionPreset.expand.animation(reduceMotion: false)) { demo.expandedRow.toggle() }
                })
                if demo.expandedRow {
                    AtticQuickLook(subtasks: Array(AtticGallerySamples.subtasks.prefix(2)))
                        .transition(.opacity)
                }
            }
        }
        BoardHeading(title: "Task card · recessed, radius 10")
        Group {
            AtticSpecimen("Collapsed", fullWidth: true) {
                AtticTaskCard(model: .init(title: "Go to the appointment", priority: .high)).padding(.horizontal, 16)
            }
            AtticSpecimen("Collapsed with details", fullWidth: true) {
                AtticTaskCard(model: .init(title: "Go to the appointment", priority: .high, due: .init(text: "Thu", isUrgent: false), tags: ["personal"], subtasks: (1, 3)))
                    .padding(.horizontal, 16)
            }
            AtticSpecimen("Hover", fullWidth: true) {
                AtticTaskCard(model: .init(title: "Ask Sam for the copy", priority: .medium, due: .init(text: "Thu", isUrgent: false)))
                    .padding(.horizontal, 16).atticForcedState(.hover)
            }
            AtticSpecimen("Expanded", fullWidth: true) {
                AtticTaskCard(
                    model: .init(title: "Go to the appointment", state: .inProgress, priority: .high, due: .init(text: "Thu", isUrgent: false), tags: ["personal"], subtasks: (1, 3)),
                    subtasks: [.init(title: "Bring insurance card", isDone: true), .init(title: "Leave by 2:15"), .init(title: "Ask about the X-ray")],
                    isExpanded: true
                )
                .padding(.horizontal, 16)
            }
        }
    }
}

// MARK: Tags

private struct TagsBoard: View {
    var body: some View {
        BoardHeading(title: "Tag chip · 18 tall, radius 6, accent")
        SpecimenRow {
            AtticSpecimen("Rest") { AtticTagChip(name: "launch") }
            AtticSpecimen("Hover") { AtticTagChip(name: "launch").atticForcedState(.hover) }
            AtticSpecimen("Filtering") { AtticTagChip(name: "launch", isSelected: true) }
        }
        SpecimenRow {
            AtticSpecimen("Inline, in a details line") {
                HStack(spacing: 0) {
                    AtticText(verbatim: "Fri · ", style: .rowMeta, ink: .helper)
                    AtticTagChip(name: "launch", style: .inline)
                }
            }
        }
        SpecimenRow {
            AtticSpecimen("Under a note title") {
                HStack(spacing: 6) {
                    AtticTagChip(name: "personal")
                    AtticTagChip(name: "health")
                    AtticText(verbatim: "1 task", style: .rowMeta, ink: .helper)
                }
            }
        }
    }
}

// MARK: Feedback

private struct FeedbackBoard: View {
    @Bindable var demo: AtticGalleryDemo
    @Environment(\.atticDesign) private var design

    var body: some View {
        BoardHeading(title: "Undo toast · 36 tall, radius 11.5, stays 6 s")
        AtticSpecimen("Deleted", fullWidth: true) {
            AtticUndoToast(message: String(localized: "Task deleted")).padding(.horizontal, 16)
        }
        AtticSpecimen("Undo hover", fullWidth: true) {
            AtticUndoToast(message: String(localized: "Moved to Backlog")).padding(.horizontal, 16).atticForcedState(.hover)
        }
        AtticSpecimen("Live: slides up, fades under Reduce Motion", fullWidth: true) {
            VStack(alignment: .leading, spacing: 8) {
                AtticRaisedButton(systemName: nil, title: demo.toastShown ? "Hide toast" : "Show toast") {
                    withAnimation(AtticMotionPreset.toast.animation(reduceMotion: design.reduceMotion)) { demo.toastShown.toggle() }
                }
                ZStack(alignment: .leading) {
                    Color.clear.frame(height: 36)
                    if demo.toastShown {
                        AtticUndoToast(message: String(localized: "Note deleted"))
                            .transition(AtticMotionPreset.toast.transition(reduceMotion: design.reduceMotion))
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        BoardHeading(title: "Empty · one quiet italic line, where the first row goes")
        AtticSpecimen("Now", fullWidth: true) { AtticEmptyLine(text: String(localized: "Nothing here yet. Add a task below.")) }
        AtticSpecimen("Done", fullWidth: true) { AtticEmptyLine(text: String(localized: "Finished tasks collect here.")) }
        AtticSpecimen("Search with no results", fullWidth: true) { AtticEmptyLine(text: String(localized: "No tasks match “invoice”.")) }
        BoardHeading(title: "Error · never hidden, with the next step")
        AtticSpecimen("Save failed", fullWidth: true) {
            AtticErrorLine(message: String(localized: "Not saved")).padding(.leading, AtticLayout.textX)
        }
        AtticSpecimen("Retry hover", fullWidth: true) {
            AtticErrorLine(message: String(localized: "Not saved")).padding(.leading, AtticLayout.textX).atticForcedState(.hover)
        }
        BoardHeading(title: "Loading · static skeleton, no shimmer")
        AtticSpecimen("List loading", fullWidth: true) { AtticLoadingRows(count: 3) }
        AtticSpecimen("Control working", fullWidth: true) {
            HStack(spacing: 12) {
                Button {} label: {
                    AtticSpinner().frame(width: 36, height: 32)
                }
                .buttonStyle(AtticRaisedButtonStyle(cornerRadius: 10))
                AtticText("Saving…", style: .rowMeta, ink: .helper)
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: Focus and selection

private struct FocusBoard: View {
    @Environment(\.atticDesign) private var design

    var body: some View {
        let tokens = design.tokens
        BoardHeading(title: "Hover is lighter than selected; pressed is darker")
        AtticSpecimen("Rest · hover · selected · pressed", fullWidth: true) {
            HStack(spacing: 8) {
                ForEach(Array([AtticRGBA.clear, tokens.hover, tokens.selected, tokens.pressed].enumerated()), id: \.offset) { index, fill in
                    ZStack {
                        AtticHighlight(fill: fill)
                        AtticText(verbatim: ["Rest", "Hover", "Selected", "Pressed"][index], style: .rowMeta, ink: .body)
                    }
                    .frame(width: 64, height: 30)
                }
            }
            .padding(.horizontal, 16)
        }
        BoardHeading(title: "Keyboard focus · 2 pt ring, 2 pt gap, radius + offset")
        SpecimenRow {
            AtticSpecimen("Button") { AtticRaisedButton(systemName: "pin", label: "Pin") {}.atticForcedState(.focused) }
            AtticSpecimen("Small control") { AtticSmallButton(systemName: "flag", label: "Priority") {}.atticForcedState(.focused) }
            AtticSpecimen("Tile") {
                RoundedRectangle(cornerRadius: AtticRadius.tile, style: .continuous)
                    .fill(tokens.recessed.color)
                    .frame(width: 60, height: 40)
                    .atticFocusRing(true, cornerRadius: AtticRadius.tile)
            }
        }
        AtticSpecimen("Row", fullWidth: true) { AtticTaskRow(model: AtticGallerySamples.rows[2]).atticForcedState(.focused) }
        BoardHeading(title: "Selection runs · one shape, outer corners only")
        AtticSpecimen("Single, then a run of three", fullWidth: true) {
            VStack(spacing: 0) {
                AtticTaskRow(model: AtticGallerySamples.rows[3], isSelected: true)
                AtticTaskRow(model: AtticGallerySamples.rows[2])
                AtticTaskRow(model: AtticGallerySamples.rows[1], isSelected: true, selectionRun: .first)
                AtticTaskRow(model: AtticGallerySamples.rows[2], isSelected: true, selectionRun: .middle)
                AtticTaskRow(model: AtticGallerySamples.rows[3], isSelected: true, selectionRun: .last)
            }
        }
    }
}

// MARK: Edge blur

private struct EdgeBlurBoard: View {
    @Environment(\.atticCapture) private var capture

    var body: some View {
        BoardHeading(title: "Content fades under a surface veil (≤ 65 %) over the soft blur")
        AtticSpecimen("Top 56 pt, bottom 60 pt", fullWidth: true) {
            Color.clear
                .frame(height: 300)
                .overlay(alignment: .top) { list }
                .overlay {
                    VStack(spacing: 0) {
                        AtticEdgeVeil(edge: .top, height: AtticEdgeBlur.panelTop)
                        Spacer(minLength: 0)
                        AtticEdgeVeil(edge: .bottom, height: AtticEdgeBlur.panelBottom)
                    }
                }
                .overlay {
                    VStack {
                        HStack {
                            AtticRaisedButton(systemName: "pin", label: "Pin") {}
                            Spacer()
                        }
                        Spacer()
                        AtticAddBar(placeholder: "Add a task…", text: .constant(""))
                    }
                    .padding(AtticSpacing.panelMargin)
                }
                .clipped()
        }
    }

    @ViewBuilder
    private var list: some View {
        let rows = (0..<3).flatMap { _ in AtticGallerySamples.rows.prefix(4) }.map { row -> AtticTaskRowModel in
            var copy = row
            copy.id = UUID()
            return copy
        }
        if capture != nil {
            VStack(spacing: 0) {
                ForEach(rows) { AtticTaskRow(model: $0) }
            }
            .offset(y: 12)
            .environment(\.atticProbesDisabled, true)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: AtticEdgeBlur.panelTop)
                    ForEach(rows) { AtticTaskRow(model: $0) }
                    Color.clear.frame(height: AtticEdgeBlur.panelBottom)
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
        }
    }
}

// MARK: Drag and drop

private struct DragBoard: View {
    @Bindable var demo: AtticGalleryDemo
    @Environment(\.atticDesign) private var design

    var body: some View {
        BoardHeading(title: "Carry · a small tilted card; several make a stack")
        SpecimenRow {
            AtticSpecimen("Task") {
                AtticCarryPreview(item: .task(title: "Email beta testers", state: .todo, priority: .medium))
                    .padding(6)
            }
        }
        SpecimenRow {
            AtticSpecimen("Image") {
                AtticCarryPreview(item: .file(name: "beta-invite.png")).padding(6)
            }
            AtticSpecimen("Stack of 3") {
                AtticCarryPreview(item: .file(name: "3 images"), count: 3).padding(.top, 10).padding(.trailing, 10)
            }
        }
        BoardHeading(title: "Reorder · the row lifts straight up, others slide apart")
        AtticSpecimen("Lifted row", fullWidth: true) {
            VStack(spacing: 0) {
                AtticTaskRow(model: AtticGallerySamples.rows[3])
                Color.clear.frame(height: 10)
                AtticReorderLift { AtticTaskRow(model: AtticGallerySamples.rows[1]) }
                Color.clear.frame(height: 10)
                AtticTaskRow(model: AtticGallerySamples.rows[2])
            }
        }
        BoardHeading(title: "Drop target · words only when not obvious")
        AtticSpecimen("File over a row", fullWidth: true) {
            AtticTaskRow(model: .init(title: "Email beta testers", priority: .medium, due: .init(text: "Fri", isUrgent: false)), dropLabel: String(localized: "Add to page"))
        }
        AtticSpecimen("Task over the Backlog tab (no words needed)", fullWidth: true) {
            AtticStatusTabs(items: AtticGallerySamples.tabs, selection: .constant(0), dropTargetTab: 1)
                .padding(.leading, AtticLayout.circleX)
        }
        AtticSpecimen("Live: settle with the tick, or fail and return", fullWidth: true) {
            DropDemo(demo: demo)
        }
    }
}

private struct DropDemo: View {
    @Bindable var demo: AtticGalleryDemo
    @Environment(\.atticDesign) private var design
    @State private var offset = CGSize(width: 0, height: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AtticRaisedButton(systemName: nil, title: "Drop") { play(success: true) }
                AtticRaisedButton(systemName: nil, title: "Failed drop") { play(success: false) }
            }
            .padding(.horizontal, 16)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: AtticRadius.highlight, style: .continuous)
                    .strokeBorder(design.tokens.divider.color, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: 180, height: 36)
                    .padding(.leading, 120)
                    .padding(.top, 36)
                AtticCarryPreview(item: .task(title: "Book dentist", state: .todo, priority: .none))
                    .offset(offset)
                    .padding(.leading, 16)
            }
            .frame(height: 84, alignment: .topLeading)
        }
    }

    private func play(success: Bool) {
        let target = CGSize(width: 104, height: 36)
        offset = .zero
        if success {
            withAnimation(AtticMotionPreset.settle.animation(reduceMotion: design.reduceMotion)) { offset = target }
            DispatchQueue.main.asyncAfter(deadline: .now() + AtticMotionPreset.settle.duration) {
                AtticHaptics.tick(enabled: design.hapticsEnabled)
            }
        } else {
            withAnimation(AtticMotionPreset.settle.animation(reduceMotion: design.reduceMotion)) { offset = target }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(AtticMotionPreset.failReturn.animation(reduceMotion: design.reduceMotion)) { offset = .zero }
            }
        }
    }
}

// MARK: Settings

private struct SettingsBoard: View {
    @Bindable var demo: AtticGalleryDemo

    var body: some View {
        AtticSpecimen("Settings · Appearance", fullWidth: true) {
            AtticGallerySettingsWindow(demo: demo)
        }
    }
}

struct AtticGallerySettingsWindow: View {
    @Bindable var demo: AtticGalleryDemo

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
                .frame(width: AtticLayout.settingsSidebarWidth)
            AtticContentCard {
                VStack(alignment: .leading, spacing: 0) {
                    AtticSettingsHeader(title: String(localized: "Appearance"))
                    Color.clear.frame(height: AtticSpacing.settingsBelowHeader - AtticSpacing.s12)
                    content
                        .padding(.horizontal, AtticSpacing.settingsGroupInset)
                }
            }
            // 8 pt from the window edges; the sidebar's own trailing 8 pt
            // (its rows are inset 8) makes the gap to the sidebar.
            .padding([.top, .bottom, .trailing], AtticSpacing.settingsCardInset)
        }
        .frame(width: 760, height: 790)
        .background(AtticSidebarBackground())
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 44)
            AtticSidebarHeading(title: String(localized: "App"))
            AtticSidebarRow(systemName: "gearshape", title: String(localized: "General"))
            AtticSidebarRow(systemName: "sidebar.left", title: String(localized: "Panel")).atticForcedState(.hover)
            AtticSidebarRow(systemName: "circle.lefthalf.filled", title: String(localized: "Appearance"), isSelected: true)
            AtticSidebarRow(systemName: "trash", title: String(localized: "Recently Deleted"))
            Color.clear.frame(height: 16)
            AtticSidebarHeading(title: String(localized: "Connections"))
            AtticSidebarRow(systemName: "sparkles", title: String(localized: "Agent Access")).atticForcedState(.focused)
            AtticSidebarHint(text: String(localized: "Let agents read and add tasks"))
            Spacer(minLength: 0)
            AtticSidebarRow(systemName: "info.circle", title: String(localized: "About"))
                .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var content: some View {
        AtticGroupCard {
            HStack(spacing: 16) {
                AtticModeTile(choice: .system)
                AtticModeTile(choice: .light, isSelected: true)
                AtticModeTile(choice: .dark)
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        Color.clear.frame(height: AtticSpacing.settingsBetweenSections)
        AtticSectionHeading(title: String(localized: "Palette"))
        Color.clear.frame(height: AtticSpacing.settingsHeadingToCard)
        let palettes = AtticPanelTheme.allCases
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 12) {
                    ForEach(palettes.dropFirst(row * 3).prefix(3), id: \.self) { palette in
                        AtticPaletteTile(palette: palette, isSelected: palette == .original)
                    }
                }
            }
        }
        .padding(.leading, 4)
        Color.clear.frame(height: AtticSpacing.settingsBetweenSections)
        AtticSectionHeading(title: String(localized: "Surface and tint"))
        Color.clear.frame(height: AtticSpacing.settingsHeadingToCard)
        AtticGroupCard {
            AtticPopUpRow(label: String(localized: "Surface"), choices: PanelSurfaceStyle.allCases.map { ($0.rawValue, $0.title) }, selection: .constant("solid"))
            AtticGroupDivider()
            AtticPopUpRow(label: String(localized: "Tint"), choices: PanelTintLevel.allCases.map { ($0.rawValue, $0.title) }, selection: .constant("vivid"))
                .atticForcedState(.hover)
            AtticGroupDivider()
            AtticSwitchRow(title: String(localized: "Haptics"), isOn: $demo.haptics)
        }
    }
}

// MARK: Tokens

private struct TokensBoard: View {
    @Environment(\.atticDesign) private var design

    var body: some View {
        let tokens = design.tokens
        let surface = tokens.panel.composite(.typical)
        BoardHeading(title: "Text ladder · contrast on this surface")
        VStack(alignment: .leading, spacing: 4) {
            ForEach([AtticInk.heading, .body, .label, .helper, .placeholder, .accentText, .dueText, .warningText], id: \.self) { ink in
                HStack(spacing: 8) {
                    AtticText(verbatim: ink.rawValue, style: .body, ink: ink)
                        .frame(width: 110, alignment: .leading)
                    AtticText(verbatim: tokens.ink(ink).hexString, style: .rowMeta, ink: .helper)
                        .frame(width: 70, alignment: .leading)
                    AtticText(verbatim: String(format: "%.1f : 1", tokens.ink(ink).contrast(on: surface)), style: .rowMeta, ink: .helper)
                }
            }
        }
        .padding(.horizontal, 16)
        BoardHeading(title: "Non-text · 3 : 1")
        HStack(spacing: 12) {
            ForEach([AtticInk.icon, .accent, .priorityHigh, .priorityMedium, .priorityLow, .priorityNone, .doneFill], id: \.self) { ink in
                VStack(spacing: 4) {
                    Circle().fill(tokens.color(ink)).frame(width: 16, height: 16)
                    AtticText(verbatim: String(format: "%.1f", tokens.ink(ink).contrast(on: surface)), style: .rowMeta, ink: .helper)
                }
            }
        }
        .padding(.horizontal, 16)
        BoardHeading(title: "Type")
        VStack(alignment: .leading, spacing: 6) {
            AtticText(verbatim: "Note title 17 bold", style: .noteTitle, ink: .heading)
            AtticText(verbatim: "Page title 16 bold", style: .pageTitle, ink: .heading)
            AtticText(verbatim: "Section heading 14 bold", style: .sectionHeading, ink: .heading)
            AtticText(verbatim: "Heading 13 semibold", style: .panelHeading, ink: .heading)
            AtticText(verbatim: "Body 13 regular", style: .body, ink: .body)
            AtticText(verbatim: "Label 12 medium", style: .groupLabel, ink: .label)
            AtticText(verbatim: "Helper 11.5 regular", style: .helper, ink: .helper)
            AtticText(verbatim: "Hint 12.5 italic", style: .hint, ink: .helper)
        }
        .padding(.horizontal, 16)
        BoardHeading(title: "Spacing · 4 pt grid")
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(AtticSpacing.scale, id: \.self) { value in
                VStack(spacing: 4) {
                    Rectangle().fill(tokens.color(.accent)).frame(width: 10, height: value)
                    AtticText(verbatim: "\(Int(value))", style: .rowMeta, ink: .helper)
                }
            }
        }
        .padding(.horizontal, 16)
        BoardHeading(title: "Corners · continuous; controls 32 % of height")
        HStack(alignment: .bottom, spacing: 12) {
            ForEach([(28.0, "9"), (32.0, "10"), (34.0, "11"), (36.0, "11.5")], id: \.0) { height, label in
                VStack(spacing: 4) {
                    AtticRaisedBackground(cornerRadius: AtticRadius.control(height: height))
                        .frame(width: height * 1.15, height: height)
                    AtticText(verbatim: label, style: .rowMeta, ink: .helper)
                }
            }
        }
        .padding(.horizontal, 16)
        BoardHeading(title: "Motion presets")
        VStack(alignment: .leading, spacing: 3) {
            ForEach(AtticMotionPreset.allCases, id: \.self) { preset in
                AtticText(
                    verbatim: "\(preset.rawValue) · \(Int(preset.duration * 1000)) ms · RM \(preset.reducedMotion == .instant ? "instant" : "fade")",
                    style: .rowMeta, ink: .helper
                )
            }
        }
        .padding(.horizontal, 16)
    }
}
#endif
