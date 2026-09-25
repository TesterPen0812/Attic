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
    var subtasksDone: Set<String> = []
    /// The last action a specimen fired ("Complete · Book dentist"), shown in
    /// the gallery's toolbar: proof that every drawn control is wired.
    var lastAction = "None yet"

    func record(_ name: String, _ subject: String? = nil) -> () -> Void {
        { [weak self] in self?.lastAction = subject.map { "\(name) · \($0)" } ?? name }
    }

    func taskActions(_ title: String) -> AtticTaskActions {
        AtticTaskActions(
            advance: record("Advance", title),
            start: record("Start", title),
            complete: record("Complete", title),
            openPage: record("Open page", title),
            moveToBacklog: record("Move to Backlog", title),
            delete: record("Delete", title)
        )
    }
}

/// Gallery rows: the component with every action recorded in the demo.
struct GalleryTaskRow: View {
    let model: AtticTaskRowModel
    var isSelected = false
    var selectionRun: AtticSelectionRun = .single
    var isExpanded = false
    var dropLabel: String?
    var onToggleExpanded: (() -> Void)?

    @Environment(AtticGalleryDemo.self) private var demo

    var body: some View {
        AtticTaskRow(
            model: model, isSelected: isSelected, selectionRun: selectionRun, isExpanded: isExpanded, dropLabel: dropLabel,
            actions: demo.taskActions(model.title),
            onToggleExpanded: onToggleExpanded ?? demo.record("Toggle subtasks", model.title)
        )
    }
}

struct GalleryQuickLook: View {
    let subtasks: [AtticSubtaskModel]
    var task = "Finalize launch checklist"

    @Environment(AtticGalleryDemo.self) private var demo

    var body: some View {
        AtticQuickLook(
            subtasks: subtasks,
            onToggle: { demo.record("Toggle subtask", $0.title)() },
            onAddSubtask: demo.record("Add subtask", task),
            onOpenPage: demo.record("Open page", task)
        )
    }
}

struct GalleryTaskCard: View {
    let model: AtticTaskRowModel
    var subtasks: [AtticSubtaskModel] = []
    var isExpanded = false

    @Environment(AtticGalleryDemo.self) private var demo

    var body: some View {
        AtticTaskCard(
            model: model, subtasks: subtasks, isExpanded: isExpanded, container: "note Launch sync",
            actions: demo.taskActions(model.title),
            cardActions: AtticTaskCardActions(
                toggleExpanded: demo.record("Toggle card", model.title),
                toggleSubtask: { demo.record("Toggle subtask", $0.title)() },
                addSubtask: demo.record("Add subtask", model.title),
                openInTasks: demo.record("Open in Tasks", model.title)
            )
        )
    }
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
    /// "Call mom fri #family !!": the date, the tag and the priority as chips.
    @MainActor
    static var chipTokens: AtticAddBar.Tokens {
        AtticAddBar.Tokens(
            chips: [NSRange(location: 9, length: 3), NSRange(location: 13, length: 7), NSRange(location: 21, length: 2)],
            isFocused: .constant(false),
            actions: AtticTokenFieldActions(submit: { _ in }, dismissChip: { _ in }, multilinePaste: { _ in false },
                                            escape: { false }, undoFallback: {}, redoFallback: {},
                                            edited: { _, _ in }, caretMoved: { _ in })
        )
    }

    static let rows: [AtticTaskRowModel] = [
        .init(title: "Finalize launch checklist", state: .inProgress, priority: .high,
              due: .init(text: "Today", isUrgent: true), tags: ["launch"], subtasks: (1, 3)),
        .init(title: "Ship appearance PR", state: .todo, priority: .high, subtasks: (2, 4)),
        .init(title: "Email beta testers", state: .todo, priority: .medium, due: .init(text: "Fri", isUrgent: false)),
        .init(title: "Book dentist", state: .todo, priority: .none, due: .init(text: "Tomorrow", isUrgent: false)),
        .init(title: "Renew domain", state: .done, priority: .low)
    ]

    /// More rows for the live panel, so its list scrolls under the header
    /// and the add bar.
    static let moreRows: [AtticTaskRowModel] = [
        .init(title: "Draft the onboarding email", state: .todo, priority: .medium, due: .init(text: "Mon", isUrgent: false)),
        .init(title: "Review the Settings copy", state: .inProgress, priority: .low, tags: ["design"]),
        .init(title: "Pay the studio invoice", state: .todo, priority: .high, due: .init(text: "Yesterday", isUrgent: true)),
        .init(title: "Back up the photo library"),
        .init(title: "Order printer paper", state: .todo, priority: .low),
        .init(title: "Plan the team offsite", state: .todo, priority: .medium, subtasks: (0, 5)),
        .init(title: "Renew the passport", state: .todo, priority: .none, due: .init(text: "Next week", isUrgent: false)),
        .init(title: "Water the plants", state: .done),
        .init(title: "Call the bank about the card", state: .todo, priority: .high, due: .init(text: "Today", isUrgent: true)),
        .init(title: "Sketch the Canvas toolbar", state: .inProgress, priority: .medium, tags: ["canvas"]),
        .init(title: "Book the car service", due: .init(text: "Oct 3", isUrgent: false)),
        .init(title: "Send the contract back", state: .todo, priority: .medium),
        .init(title: "Tidy the Downloads folder", state: .todo, priority: .low)
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
        // Boards start below the panel's header zone (`AtticSurfaceModel.contentTop`),
        // where panel content starts, so tinted boards judge text where it sits.
        .padding(.top, family == .panel || family == .settings ? 0 : 44)
        .padding(.bottom, family == .panel || family == .settings ? 0 : 16)
        .frame(width: family.width, alignment: .topLeading)
        .environment(\.atticSpecimen, family.title)
        .environment(demo)
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
    /// Expands the first row's quick look (puts label text in the panel).
    var showsQuickLook = false
    /// Live only: where the list starts scrolled to (the glass lab shows
    /// rows under the header and the add bar).
    var initialScroll: CGFloat = 0

    @Environment(\.atticCapture) private var capture
    @State private var scroll = ScrollPosition()

    /// The panel's own coordinate space (the scroll edge zones are measured in it).
    static let space = NamedCoordinateSpace.named("AtticGalleryPanel")

    /// Above the status tabs: the header's margin, controls and gap.
    private static let headerZone = AtticSpacing.panelMargin + AtticControlSize.capsuleHeight + AtticLayout.statusTabsTop
    /// Below the list: the add bar and its margins.
    private static let footerZone = AtticControlSize.addBarHeight + AtticSpacing.panelMargin * 2

    var body: some View {
        Group {
            if capture == nil {
                live
            } else {
                still
            }
        }
        .frame(width: AtticLayout.panelSize.width, height: AtticLayout.panelSize.height)
        .coordinateSpace(Self.space)
        .background(AtticPanelStageSurface(cornerSize: 52))
        .clipShape(Squircle(cornerRadius: 52, exponent: AtticStyle.panelSquircleExponent))
        .overlay(AtticPanelRim(cornerSize: 52))
    }

    /// Live, the list scrolls under the header and the add bar, which float
    /// over it. The system's soft scroll edge does not draw under Liquid
    /// Glass bars (macOS 26: none at all under a `safeAreaBar` of glass
    /// controls, and a hard line under drawn ones), so the scroll view has
    /// no bars and no system edge effect: the rows blur and fade themselves
    /// as they pass under a control (`atticScrollEdgeFade`), the same with
    /// either control material.
    private var live: some View {
        ZStack(alignment: .top) {
            ScrollView {
                list(rows + AtticGallerySamples.moreRows, fades: true)
            }
            .contentMargins(.top, Self.headerZone, for: .scrollContent)
            .contentMargins(.bottom, Self.footerZone, for: .scrollContent)
            .scrollIndicators(.never)
            .scrollEdgeEffectHidden(true, for: .all)
            .scrollPosition($scroll)
            .onAppear { if initialScroll > 0 { scroll.scrollTo(y: initialScroll) } }
            controls
        }
    }

    /// Captures: the same layout, still (nothing scrolls in a render).
    private var still: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: Self.headerZone)
                list(rows)
                Spacer(minLength: 0)
            }
            veils
            controls
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 0)
            addBar
        }
        .padding(AtticSpacing.panelMargin)
    }

    private var veils: some View {
        VStack(spacing: 0) {
            AtticEdgeVeil(edge: .top, height: AtticEdgeBlur.panelTop)
            Spacer(minLength: 0)
            AtticEdgeVeil(edge: .bottom, height: AtticEdgeBlur.panelBottom)
        }
    }

    private var header: some View {
        AtticControlGroup {
            HStack(spacing: 0) {
                AtticRaisedButton(systemName: "pin", label: "Pin", help: "Pin (⇧⌘P)", action: demo.record("Pin"))
                Spacer(minLength: AtticSpacing.betweenControls)
                AtticPageSwitch(items: AtticGallerySamples.pages, selection: $demo.page)
            }
        }
    }

    private var addBar: some View {
        AtticAddBar(placeholder: "Add a task…", text: $demo.addText) { demo.addText = "" }
    }

    private func list(_ rows: [AtticTaskRowModel], fades: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AtticStatusTabs(items: AtticGallerySamples.tabs, selection: $demo.tab)
                .padding(.leading, AtticLayout.circleX)
                .atticScrollEdgeFade(fades, in: Self.space)
            Color.clear.frame(height: AtticLayout.statusTabsToList)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                GalleryTaskRow(model: row, isSelected: index == selectedIndex, isExpanded: showsQuickLook && index == 0)
                    .atticScrollEdgeFade(fades, in: Self.space)
                if showsQuickLook, index == 0 {
                    GalleryQuickLook(subtasks: AtticGallerySamples.subtasks)
                        .atticScrollEdgeFade(fades, in: Self.space)
                }
            }
            AtticEmptyLine(text: String(localized: "Done tasks move to Done tomorrow"))
                .atticScrollEdgeFade(fades, in: Self.space)
        }
    }
}


// MARK: Raised controls

private struct RaisedControlsBoard: View {
    @Environment(AtticGalleryDemo.self) private var demo
    var body: some View {
        BoardHeading(title: "Single button · 36 × 32, radius 13.5")
        SpecimenRow {
            ForEach([AtticControlState.rest, .hover, .pressed], id: \.self) { state in
                AtticSpecimen(state.title) {
                    AtticRaisedButton(systemName: "pin", label: "Pin", action: demo.record("Pin")).atticForcedState(state)
                }
            }
        }
        SpecimenRow {
            ForEach([AtticControlState.focused, .disabled], id: \.self) { state in
                AtticSpecimen(state.title) {
                    AtticRaisedButton(systemName: "pin", label: "Pin", action: demo.record("Pin")).atticForcedState(state)
                }
            }
            AtticSpecimen("Pinned") {
                AtticRaisedButton(systemName: "pin.fill", label: "Unpin", action: demo.record("Unpin"))
            }
        }
        BoardHeading(title: "Label buttons · 32 tall")
        SpecimenRow {
            AtticSpecimen("All notes") {
                AtticRaisedButton(systemName: "list.bullet", title: "All notes", action: demo.record("All notes"))
            }
            AtticSpecimen("New note, hover") {
                AtticRaisedButton(systemName: "square.and.pencil", title: "New note", action: demo.record("New note")).atticForcedState(.hover)
            }
        }
        BoardHeading(title: "Settings back button · 38 × 34, radius 14.5")
        SpecimenRow {
            ForEach([AtticControlState.rest, .hover, .pressed, .focused], id: \.self) { state in
                AtticSpecimen(state.title) {
                    AtticRaisedButton(systemName: "chevron.left", label: "Back", size: AtticControlSize.settingsBackButton, action: demo.record("Back"))
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
        BoardHeading(title: "Group capsule · 32 tall, chips 24, radius 9.5, inset 4")
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
        BoardHeading(title: "Add bar · 36 tall, radius 15; send appears with text")
        Group {
            AtticSpecimen("Empty", fullWidth: true) {
                AtticAddBar(placeholder: "Add a task…", text: .constant(""), onSubmit: demo.record("Add")).padding(.horizontal, 12)
            }
            AtticSpecimen("Hover: no fill; the cursor becomes the I-beam", fullWidth: true) {
                AtticAddBar(placeholder: "Add a task…", text: .constant(""), onSubmit: demo.record("Add")).padding(.horizontal, 12).atticForcedState(.hover)
            }
            AtticSpecimen("With text: send button inside", fullWidth: true) {
                AtticAddBar(placeholder: "Add a task…", text: .constant(demo.addTextFilled), onSubmit: demo.record("Add")).padding(.horizontal, 12)
            }
            AtticSpecimen("Backlog page", fullWidth: true) {
                AtticAddBar(placeholder: "Add to backlog…", text: .constant(""), onSubmit: demo.record("Add")).padding(.horizontal, 12)
            }
            AtticSpecimen("Recognised pieces become chips (Phase 1)", fullWidth: true) {
                AtticAddBar(placeholder: "Add a task…", text: .constant("Call mom fri #family !!"),
                            tokens: AtticGallerySamples.chipTokens, onSubmit: demo.record("Add"))
                    .padding(.horizontal, 12)
            }
            AtticSpecimen("Done page: the bar searches (Phase 1)", fullWidth: true) {
                AtticAddBar(placeholder: "Search done tasks…", text: .constant(""), systemImage: "magnifyingglass",
                            showsSend: false, tokens: nil, onSubmit: {})
                    .padding(.horizontal, 12)
            }
            AtticSpecimen("Keyboard focus", fullWidth: true) {
                AtticAddBar(placeholder: "Add a task…", text: .constant(""), onSubmit: demo.record("Add")).padding(.horizontal, 12).atticForcedState(.focused)
            }
            AtticSpecimen("Live (type to see the send button)", fullWidth: true) {
                AtticAddBar(placeholder: "Add a task…", text: $demo.addText) { demo.addText = "" }.padding(.horizontal, 12)
            }
        }
    }
}

// MARK: Small controls and menus

private struct SmallControlsBoard: View {
    @Environment(AtticGalleryDemo.self) private var demo
    var body: some View {
        BoardHeading(title: "Selection bar · small controls 28 tall, radius 12")
        AtticSpecimen("Selection bar", fullWidth: true) {
            AtticSelectionBar(count: 3, actions: [
                .init(systemName: "circle.dashed", label: "State", handler: demo.record("State")),
                .init(systemName: "flag", label: "Priority", handler: demo.record("Priority")),
                .init(systemName: "number", label: "Tag", handler: demo.record("Tag")),
                .init(systemName: "arrow.right.square", label: "Move", handler: demo.record("Move")),
                .init(systemName: "trash", label: "Delete", handler: demo.record("Delete"))
            ])
            .padding(.horizontal, 16)
        }
        SpecimenRow {
            ForEach([AtticControlState.rest, .hover, .pressed, .focused, .disabled], id: \.self) { state in
                AtticSpecimen(state == .focused ? "Focus" : state.title) {
                    AtticSmallButton(systemName: "flag", label: "Priority", action: demo.record("Priority")).atticForcedState(state)
                }
            }
        }
        BoardHeading(title: "Title menu · native menu, Attic's title")
        SpecimenRow {
            AtticSpecimen("Title (click: the system menu)") {
                AtticTitleMenu(title: "Launch sync", commands: titleCommands)
            }
            AtticSpecimen("Hover") {
                AtticTitleMenu(title: "Launch sync", commands: titleCommands).atticForcedState(.hover)
            }
        }
        BoardHeading(title: "Pop-over · radius 20; rows 28, radius 12")
        SpecimenRow {
            AtticSpecimen("Link picker (Attic's own pop-over content)") {
                AtticPopover(width: 236) {
                    AtticPopoverRow(systemName: "note.text", title: "Launch sync", detail: "Note", isHighlighted: true, action: demo.record("Link", "Launch sync"))
                    AtticPopoverRow(systemName: "scribble.variable", title: "Roadmap sketch", detail: "Canvas", action: demo.record("Link", "Roadmap sketch"))
                    AtticPopoverRow(systemName: "checkmark.circle", title: "Email beta testers", detail: "Task", action: demo.record("Link", "Email beta testers"))
                    AtticPopoverGap()
                    AtticPopoverRow(systemName: "note.text", title: "This note", detail: "Can't link", action: demo.record("Link", "This note"))
                        .disabled(true)
                }
            }
        }
    }

    /// The title menu's commands: the system draws the menu, its keyboard
    /// navigation, shortcuts and separators.
    private var titleCommands: [AtticMenuCommand] {
        [
            AtticMenuCommand("Open in window", systemImage: "macwindow", shortcut: KeyboardShortcut("o", modifiers: [.command, .shift]), action: demo.record("Open in window")),
            AtticMenuCommand("Duplicate", systemImage: "plus.square.on.square", shortcut: KeyboardShortcut("d", modifiers: .command), action: demo.record("Duplicate")),
            AtticMenuCommand("Export…", systemImage: "square.and.arrow.up", isDisabled: true, action: demo.record("Export")),
            AtticMenuCommand("Delete", systemImage: "trash", shortcut: KeyboardShortcut(.delete, modifiers: .command), isDestructive: true, startsSection: true, action: demo.record("Delete"))
        ]
    }
}

// MARK: Status circle

private struct StatusCircleBoard: View {
    @Bindable var demo: AtticGalleryDemo

    /// Ticked of three subtasks, and none at all.
    private static let fractions: [(title: String, subtasks: (done: Int, total: Int)?)] = [
        ("0 of 3", (0, 3)), ("1 of 3", (1, 3)), ("2 of 3", (2, 3)), ("No subtasks", nil)
    ]

    var body: some View {
        BoardHeading(title: "States × priorities · 16 pt · weight shows priority, only High is red")
        VStack(alignment: .leading, spacing: 10) {
            ForEach(AtticTaskState.allCases, id: \.self) { state in
                AtticSpecimen(stateTitle(state), fullWidth: true) {
                    priorities { AtticStatusCircle(state: state, priority: $0) }
                }
            }
        }
        BoardHeading(title: "In progress · the wedge is the share of subtasks ticked (at least a quarter)")
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.fractions, id: \.title) { fraction in
                AtticSpecimen(fraction.title, fullWidth: true) {
                    priorities { AtticStatusCircle(state: .inProgress, priority: $0, progress: AtticStatusCircle.progress(fraction.subtasks)) }
                }
            }
        }
        BoardHeading(title: "Completion · the wedge sweeps to a full disc, then the check draws")
        AtticSpecimen("Frames from 1 of 3: sweep 0, 50, 100 %, then check 50, 100 %", fullWidth: true) {
            HStack(spacing: 22) {
                ForEach(Array([(0.0, 0.0), (0.5, 0.0), (1.0, 0.0), (1.0, 0.5), (1.0, 1.0)].enumerated()), id: \.offset) { _, frame in
                    // Frames of the animation: the in-between frames are
                    // transient, so only the settled frame is judged.
                    AtticStatusCircle(state: .done, priority: .high, progress: 1.0 / 3, checkProgress: frame.1, completionProgress: frame.0)
                        .transformEnvironment(\.atticProbesDisabled) { if frame.1 < 1 { $0 = true } }
                }
            }
            .padding(.horizontal, 16)
        }
        AtticSpecimen("Live: click the circle to advance (1 of 3 subtasks)", fullWidth: true) {
            HStack(spacing: 10) {
                AtticStatusButton(state: demo.liveState, priority: .medium, subtasks: (1, 3)) {
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
        AtticSpecimen("Keyboard focus (Full Keyboard Access)", fullWidth: true) {
            HStack(spacing: 22) {
                AtticStatusButton(state: .todo, priority: .high, onAdvance: demo.record("Advance")).atticForcedState(.focused)
                AtticStatusButton(state: .done, priority: .none, onAdvance: demo.record("Advance")).atticForcedState(.focused)
            }
            .padding(.horizontal, 10)
        }
        AtticSpecimen("Differentiate Without Colour: High is heavier than Medium", fullWidth: true) {
            VStack(alignment: .leading, spacing: 8) {
                priorities { AtticStatusCircle(state: .todo, priority: $0) }
                priorities { AtticStatusCircle(state: .inProgress, priority: $0, progress: 1.0 / 3) }
            }
            .transformEnvironment(\.atticDesign) { $0.differentiateWithoutColor = true }
        }
    }

    /// One circle per priority, labelled.
    private func priorities(@ViewBuilder _ circle: @escaping (AtticPriority) -> some View) -> some View {
        HStack(spacing: 22) {
            ForEach(AtticPriority.allCases, id: \.self) { priority in
                VStack(spacing: 4) {
                    circle(priority)
                    AtticText(verbatim: priority.rawValue.capitalized, style: .rowMeta, ink: .helper)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func stateTitle(_ state: AtticTaskState) -> String {
        switch state {
        case .todo: "To do: a grey ring, heavier and darker with priority; High is red"
        case .inProgress: "In progress, no subtasks: a quarter wedge (started)"
        case .done: "Done: a quiet grey disc with a darker check"
        case .backlog: "Backlog: a dashed grey ring"
        }
    }
}

// MARK: Task rows

private struct TaskRowsBoard: View {
    @Environment(AtticGalleryDemo.self) private var demo
    var body: some View {
        let rows = AtticGallerySamples.rows
        BoardHeading(title: "32 pt; 44 pt with a details line")
        AtticSpecimen("Rest", fullWidth: true) { GalleryTaskRow(model: rows[2]) }
        AtticSpecimen("Details line: today, tag", fullWidth: true) { GalleryTaskRow(model: rows[0]) }
        AtticSpecimen("Date and count on the title line", fullWidth: true) {
            GalleryTaskRow(model: .init(title: "Plan the offsite", priority: .low, due: .init(text: "Mon", isUrgent: false), subtasks: (0, 2)))
        }
        AtticSpecimen("Overdue at the right end", fullWidth: true) {
            GalleryTaskRow(model: .init(title: "Pay the invoice", priority: .high, due: .init(text: "Yesterday", isUrgent: true)))
        }
        AtticSpecimen("Hover", fullWidth: true) { GalleryTaskRow(model: rows[1]).atticForcedState(.hover) }
        AtticSpecimen("Selected", fullWidth: true) { GalleryTaskRow(model: rows[1], isSelected: true) }
        AtticSpecimen("Pressed", fullWidth: true) { GalleryTaskRow(model: rows[1]).atticForcedState(.pressed) }
        AtticSpecimen("Keyboard focus", fullWidth: true) { GalleryTaskRow(model: rows[3]).atticForcedState(.focused) }
        AtticSpecimen("Disabled (while saving)", fullWidth: true) { GalleryTaskRow(model: rows[3]).atticForcedState(.disabled) }
        AtticSpecimen("Done: struck through, faded", fullWidth: true) { GalleryTaskRow(model: rows[4]) }
        AtticSpecimen("Backlog", fullWidth: true) {
            GalleryTaskRow(model: .init(title: "Plan Friday retro", state: .backlog, priority: .low))
        }
        AtticSpecimen("Touching selected rows merge", fullWidth: true) {
            VStack(spacing: 0) {
                GalleryTaskRow(model: rows[1], isSelected: true, selectionRun: .first)
                GalleryTaskRow(model: rows[2], isSelected: true, selectionRun: .middle)
                GalleryTaskRow(model: rows[3], isSelected: true, selectionRun: .last)
            }
        }
        AtticSpecimen("In a window; date, files and links", fullWidth: true) {
            GalleryTaskRow(model: .init(title: "Draft the pricing page", priority: .medium, due: .init(text: "Thu", isUrgent: false), attachments: 2, links: 2, inWindow: true))
        }
        AtticSpecimen("A very long title truncates, never wraps", fullWidth: true) {
            GalleryTaskRow(model: .init(title: "Write the long overdue follow-up to everyone who replied to the beta invite", subtasks: (0, 5)))
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
                GalleryTaskRow(model: AtticGallerySamples.rows[0], isSelected: true, isExpanded: true)
                GalleryQuickLook(subtasks: AtticGallerySamples.subtasks)
            }
        }
        AtticSpecimen("Live: click the count", fullWidth: true) {
            VStack(spacing: 0) {
                GalleryTaskRow(model: AtticGallerySamples.rows[1], isExpanded: demo.expandedRow, onToggleExpanded: {
                    withAnimation(AtticMotionPreset.expand.animation(reduceMotion: false)) { demo.expandedRow.toggle() }
                })
                if demo.expandedRow {
                    GalleryQuickLook(subtasks: Array(AtticGallerySamples.subtasks.prefix(2)))
                        .transition(.opacity)
                }
            }
        }
        BoardHeading(title: "Task card · recessed, radius 10")
        Group {
            AtticSpecimen("Collapsed", fullWidth: true) {
                GalleryTaskCard(model: .init(title: "Go to the appointment", priority: .high)).padding(.horizontal, 16)
            }
            AtticSpecimen("Collapsed with details", fullWidth: true) {
                GalleryTaskCard(model: .init(title: "Go to the appointment", priority: .high, due: .init(text: "Thu", isUrgent: false), tags: ["personal"], subtasks: (1, 3)))
                    .padding(.horizontal, 16)
            }
            AtticSpecimen("Hover", fullWidth: true) {
                GalleryTaskCard(model: .init(title: "Ask Sam for the copy", priority: .medium, due: .init(text: "Thu", isUrgent: false)))
                    .padding(.horizontal, 16).atticForcedState(.hover)
            }
            AtticSpecimen("Expanded", fullWidth: true) {
                GalleryTaskCard(
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
    @Environment(AtticGalleryDemo.self) private var demo
    var body: some View {
        BoardHeading(title: "Tag chip · 18 tall, radius 7.5, accent")
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
        BoardHeading(title: "Undo toast · 36 tall, radius 15, stays 6 s")
        AtticSpecimen("Deleted", fullWidth: true) {
            AtticUndoToast(message: String(localized: "Task deleted"), onUndo: demo.record("Undo")).padding(.horizontal, 16)
        }
        AtticSpecimen("Undo hover", fullWidth: true) {
            AtticUndoToast(message: String(localized: "Moved to Backlog"), onUndo: demo.record("Undo")).padding(.horizontal, 16).atticForcedState(.hover)
        }
        AtticSpecimen("Live: slides up, fades under Reduce Motion", fullWidth: true) {
            VStack(alignment: .leading, spacing: 8) {
                AtticRaisedButton(systemName: nil, title: demo.toastShown ? "Hide toast" : "Show toast") {
                    withAnimation(AtticMotionPreset.toast.animation(reduceMotion: design.reduceMotion)) { demo.toastShown.toggle() }
                }
                ZStack(alignment: .leading) {
                    Color.clear.frame(height: 36)
                    if demo.toastShown {
                        AtticUndoToast(message: String(localized: "Note deleted"), onUndo: demo.record("Undo"))
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
            AtticErrorLine(message: String(localized: "Not saved"), onRetry: demo.record("Retry")).padding(.leading, AtticLayout.textX)
        }
        AtticSpecimen("Retry hover", fullWidth: true) {
            AtticErrorLine(message: String(localized: "Not saved"), onRetry: demo.record("Retry")).padding(.leading, AtticLayout.textX).atticForcedState(.hover)
        }
        BoardHeading(title: "Loading · static skeleton, no shimmer")
        AtticSpecimen("List loading", fullWidth: true) { AtticLoadingRows(count: 3) }
        AtticSpecimen("Control working", fullWidth: true) {
            HStack(spacing: 12) {
                Button(action: demo.record("Working control")) {
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
    @Environment(AtticGalleryDemo.self) private var demo
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
            AtticSpecimen("Button") { AtticRaisedButton(systemName: "pin", label: "Pin", action: demo.record("Pin")).atticForcedState(.focused) }
            AtticSpecimen("Small control") { AtticSmallButton(systemName: "flag", label: "Priority", action: demo.record("Priority")).atticForcedState(.focused) }
            AtticSpecimen("Tile") {
                RoundedRectangle(cornerRadius: AtticRadius.tile, style: .continuous)
                    .fill(tokens.recessed.color)
                    .frame(width: 60, height: 40)
                    .atticFocusRing(true, cornerRadius: AtticRadius.tile)
            }
        }
        AtticSpecimen("Row", fullWidth: true) { GalleryTaskRow(model: AtticGallerySamples.rows[2]).atticForcedState(.focused) }
        BoardHeading(title: "Selection runs · one shape, outer corners only")
        AtticSpecimen("Single, then a run of three", fullWidth: true) {
            VStack(spacing: 0) {
                GalleryTaskRow(model: AtticGallerySamples.rows[3], isSelected: true)
                GalleryTaskRow(model: AtticGallerySamples.rows[2])
                GalleryTaskRow(model: AtticGallerySamples.rows[1], isSelected: true, selectionRun: .first)
                GalleryTaskRow(model: AtticGallerySamples.rows[2], isSelected: true, selectionRun: .middle)
                GalleryTaskRow(model: AtticGallerySamples.rows[3], isSelected: true, selectionRun: .last)
            }
        }
    }
}

// MARK: Edge blur

private struct EdgeBlurBoard: View {
    @Environment(AtticGalleryDemo.self) private var demo
    @Environment(\.atticCapture) private var capture

    var body: some View {
        BoardHeading(title: "Content blurs (≤ 6 pt) and fades (≤ 65 %) under the controls")
        AtticSpecimen("Top 56 pt, bottom 60 pt", fullWidth: true) {
            Color.clear
                .frame(height: 300)
                .overlay(alignment: .top) { list }
                .overlay {
                    // Captures draw the list still, so the fade is the veil.
                    if capture != nil {
                        VStack(spacing: 0) {
                            AtticEdgeVeil(edge: .top, height: AtticEdgeBlur.panelTop)
                            Spacer(minLength: 0)
                            AtticEdgeVeil(edge: .bottom, height: AtticEdgeBlur.panelBottom)
                        }
                    }
                }
                .overlay {
                    VStack {
                        HStack {
                            AtticRaisedButton(systemName: "pin", label: "Pin", action: demo.record("Pin"))
                            Spacer()
                        }
                        Spacer()
                        AtticAddBar(placeholder: "Add a task…", text: .constant(""), onSubmit: demo.record("Add"))
                    }
                    .padding(AtticSpacing.panelMargin)
                }
                .coordinateSpace(Self.space)
                .clipped()
        }
    }

    private static let space = NamedCoordinateSpace.named("AtticEdgeBlurSpecimen")

    @ViewBuilder
    private var list: some View {
        let rows = (0..<3).flatMap { _ in AtticGallerySamples.rows.prefix(4) }.map { row -> AtticTaskRowModel in
            var copy = row
            copy.id = UUID()
            return copy
        }
        if capture != nil {
            VStack(spacing: 0) {
                ForEach(rows) { GalleryTaskRow(model: $0) }
            }
            .offset(y: -4)
            .environment(\.atticProbesDisabled, true)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: AtticEdgeBlur.panelTop)
                    ForEach(rows) { GalleryTaskRow(model: $0).atticScrollEdgeFade(in: Self.space) }
                    Color.clear.frame(height: AtticEdgeBlur.panelBottom)
                }
            }
            .scrollEdgeEffectHidden(true, for: .all)
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
                GalleryTaskRow(model: AtticGallerySamples.rows[3])
                Color.clear.frame(height: 10)
                AtticReorderLift { GalleryTaskRow(model: AtticGallerySamples.rows[1]) }
                Color.clear.frame(height: 10)
                GalleryTaskRow(model: AtticGallerySamples.rows[2])
            }
        }
        BoardHeading(title: "Drop target · words only when not obvious")
        AtticSpecimen("File over a row", fullWidth: true) {
            GalleryTaskRow(model: .init(title: "Email beta testers", priority: .medium, due: .init(text: "Fri", isUrgent: false)), dropLabel: String(localized: "Add to page"))
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
        AtticSpecimen("Settings · Appearance, at rest", fullWidth: true) {
            AtticGallerySettingsWindow(demo: demo)
        }
        AtticSpecimen("General · behaviour group (Haptics lives here)", fullWidth: true) {
            AtticGroupCard {
                AtticPopUpRow(label: String(localized: "Open Attic on"), choices: [("last", String(localized: "Last page")), ("tasks", String(localized: "Tasks"))], selection: .constant("last"))
                AtticGroupDivider()
                AtticSwitchRow(title: String(localized: "Haptics"), isOn: $demo.haptics)
            }
            .frame(width: 480)
            .padding(16)
            .background(AtticContentCard { Color.clear })
            .padding(.horizontal, 16)
        }
    }
}

/// The Appearance page at rest: only the current page selected, the
/// current choices showing the design context the sheet is drawn in.
struct AtticGallerySettingsWindow: View {
    @Bindable var demo: AtticGalleryDemo
    @Environment(\.atticDesign) private var design

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
                .frame(width: AtticLayout.settingsSidebarWidth)
            AtticContentCard {
                VStack(alignment: .leading, spacing: 0) {
                    AtticSettingsHeader(title: String(localized: "Appearance"), onBack: demo.record("Back"))
                    Color.clear.frame(height: AtticSpacing.settingsBelowHeader - AtticSpacing.s12)
                    content
                        .padding(.horizontal, AtticSpacing.settingsGroupInset)
                }
            }
            // 8 pt from the window edges; the sidebar's own trailing 8 pt
            // (its rows are inset 8) makes the gap to the sidebar.
            .padding([.top, .bottom, .trailing], AtticSpacing.settingsCardInset)
        }
        .frame(width: 760, height: 1010)
        .background(AtticSidebarBackground())
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 44)
            AtticSidebarHeading(title: String(localized: "App"))
            AtticSidebarRow(systemName: "gearshape", title: String(localized: "General"), action: demo.record("Sidebar", "General"))
            AtticSidebarRow(systemName: "sidebar.left", title: String(localized: "Panel"), action: demo.record("Sidebar", "Panel"))
            AtticSidebarRow(systemName: "circle.lefthalf.filled", title: String(localized: "Appearance"), isSelected: true, action: demo.record("Sidebar", "Appearance"))
            AtticSidebarRow(systemName: "trash", title: String(localized: "Recently Deleted"), action: demo.record("Sidebar", "Recently Deleted"))
            Color.clear.frame(height: 16)
            AtticSidebarHeading(title: String(localized: "Connections"))
            AtticSidebarRow(systemName: "sparkles", title: String(localized: "Agent Access"), action: demo.record("Sidebar", "Agent Access"))
            AtticSidebarHint(text: String(localized: "Let agents read and add tasks"))
            Spacer(minLength: 0)
            AtticSidebarRow(systemName: "info.circle", title: String(localized: "About"), action: demo.record("Sidebar", "About"))
                .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var content: some View {
        AtticAppearancePreview {
            AtticGalleryPanelComposition(demo: demo, selectedIndex: nil)
        }
        Color.clear.frame(height: AtticSpacing.s12)
        AtticGroupCard {
            HStack(spacing: 16) {
                AtticModeTile(choice: .system, action: demo.record("Mode", "System"))
                AtticModeTile(choice: .light, isSelected: design.mode == .light, action: demo.record("Mode", "Light"))
                AtticModeTile(choice: .dark, isSelected: design.mode == .dark, action: demo.record("Mode", "Dark"))
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
                        AtticPaletteTile(palette: palette, isSelected: palette == design.palette, action: demo.record("Palette", palette.title))
                    }
                }
            }
        }
        .padding(.leading, 4)
        Color.clear.frame(height: AtticSpacing.settingsBetweenSections)
        AtticSectionHeading(title: String(localized: "Surface and tint"))
        Color.clear.frame(height: AtticSpacing.settingsHeadingToCard)
        AtticGroupCard {
            AtticPopUpRow(label: String(localized: "Surface"), choices: PanelSurfaceStyle.allCases.map { ($0.rawValue, $0.title) }, selection: .constant(design.reduceTransparency ? PanelSurfaceStyle.solid.rawValue : design.surface.rawValue))
            AtticGroupDivider()
            AtticPopUpRow(label: String(localized: "Tint"), choices: PanelTintLevel.allCases.map { ($0.rawValue, $0.title) }, selection: .constant(design.tint.rawValue))
        }
        Color.clear.frame(height: AtticSpacing.settingsBetweenSections)
        AtticSectionHeading(title: String(localized: "Advanced"))
        Color.clear.frame(height: AtticSpacing.settingsHeadingToCard)
        AtticGroupCard {
            AtticSliderRow(
                label: String(localized: "Tint length"),
                valueText: design.tintLength >= 0.995 ? String(localized: "Full height") : String(localized: "\(Int((design.tintLength * 100).rounded())) % of the panel"),
                value: .constant(design.tintLength),
                range: PanelTintLength.range
            )
        }
    }
}

// MARK: Tokens

private struct TokensBoard: View {
    @Environment(\.atticDesign) private var design

    var body: some View {
        let tokens = design.tokens
        let surface = tokens.panel.composite(.midGrey, at: AtticSurfaceModel.contentTop)
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
            ForEach([AtticInk.icon, .accent, .priorityHigh, .priorityMedium, .priorityLow, .priorityNone], id: \.self) { ink in
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
        BoardHeading(title: "Corners · continuous; controls 42 % of height")
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
