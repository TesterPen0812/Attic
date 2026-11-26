import AppKit
import SwiftUI

// MARK: - A task's page opens in one piece (Accepted 2026-11-25)

// Opening a task's page from a Tasks row is one motion on the size spring:
// the row's circle and title travel to the head's place and the title grows
// into the 17 pt head; the rows above leave upward, the rows below are pushed
// down, and the subtasks unfold from under the head. Back runs it backwards.
//
// The motion is SwiftUI on a free main thread: the page's head and first
// lines are a stand-in drawn from the row's own data (`TaskPageStandIn`),
// laid out where the built page puts them. The real page is built only once
// the motion has landed, under the stand-in, and the stand-in gives way to it
// in one frame at the same places.

enum TaskPageOnePiece {
    /// The route host's space: the list's lines and the stand-in read it.
    nonisolated static let space = "task-page-one-piece"

    /// The size spring (0.28 s, bounce 0.12 in Lively).
    static var spring: Animation {
        AtticMotionPreset.expand.animation(reduceMotion: false) ?? .spring(duration: 0.28, bounce: 0.12)
    }

    /// How long after the click the page is built: the spring's main motion
    /// (its tail is sub-pixel by then).
    static var landing: Double { AtticMotionPreset.expand.duration + 0.02 }

    /// The head's first line's centre, in the page's space.
    static func headLineMid(_ layout: PanelPageLayout) -> CGFloat {
        layout.headerBottom + AtticNoteMetrics.titleTopGap + TaskNoteMetrics.titleLineHeight / 2
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    /// 0 before `from`, 1 after `to`, linear between (on the spring's progress).
    static func ramp(_ p: CGFloat, _ from: CGFloat, _ to: CGFloat) -> CGFloat {
        min(1, max(0, (p - from) / (to - from)))
    }
}

/// What the list does while a task's page opens over it: every line above
/// the opening row leaves upward with it, every line below is pushed down,
/// and the row itself fades as it leaves (its title grows as it goes).
struct TaskPageMakeWay: Equatable, Sendable {
    var anchorID: UUID
    /// The opening row's slot, in `TaskPageOnePiece.space`.
    var anchorBottom: CGFloat
    /// The row's travel to the head (negative: up).
    var rise: CGFloat
    /// How far the lines below are pushed.
    var push: CGFloat
    var open = false
}

extension EnvironmentValues {
    @Entry var taskPageMakeWay: TaskPageMakeWay? = nil
    /// This row is the one opening into its page: its title grows and fades
    /// into the head, its circle hands over to the head's.
    @Entry var taskPageRowLeaving: Bool = false
}

/// Every line of a Tasks list (applied through a Group, so to each row,
/// header and line): it moves and fades by where it sits against the
/// opening row. Offset and opacity only, so tab, scroll and selection are
/// exactly as they were after Back.
struct TaskPageMakeWayLine: ViewModifier {
    @Environment(\.taskPageMakeWay) private var way

    func body(content: Content) -> some View {
        let way = self.way
        content.visualEffect { effect, proxy in
            var dy: CGFloat = 0
            var shows: Double = 1
            if let way, way.open {
                let mid = proxy.frame(in: .named(TaskPageOnePiece.space)).midY
                dy = mid > way.anchorBottom ? way.push : way.rise
                shows = 0
            }
            return effect.offset(y: dy).opacity(shows)
        }
    }
}

/// The opening row's cell: tells its row it is the one leaving.
struct TaskPageRowLeaving: ViewModifier {
    let id: UUID
    @Environment(\.taskPageMakeWay) private var way

    func body(content: Content) -> some View {
        content.environment(\.taskPageRowLeaving, way?.open == true && way?.anchorID == id)
    }
}

/// The leaving row's title: it grows towards the head's 17 pt on the size
/// spring (the row's line travels with the list), fading by 45 % of it; on
/// Back it comes back over the motion's last part.
struct TaskPageLeavingTitle: ViewModifier {
    let leaving: Bool

    func body(content: Content) -> some View {
        let grow = AtticTextStyle.noteTitle.nsFont.pointSize / AtticTextStyle.taskTitle.nsFont.pointSize
        content
            .scaleEffect(leaving ? grow : 1, anchor: .leading)
            .animation(TaskPageOnePiece.spring, value: leaving)
            .opacity(leaving ? 0 : 1)
            .animation(leaving ? AtticMotionScale.easeOut(0.13) : AtticMotionScale.easeOut(0.12).delay(0.14), value: leaving)
    }
}

/// Tasks' own top row (Now · Later · Done): it fades as the page opens.
struct TaskPageMakeWayFade: ViewModifier {
    @Environment(\.taskPageMakeWay) private var way

    func body(content: Content) -> some View {
        let away = way?.open == true
        content
            .opacity(away ? 0 : 1)
            .animation(away ? AtticMotionScale.easeOut(AtticMotionScale.fast)
                            : AtticMotionScale.easeOut(AtticMotionScale.fast).delay(AtticMotionScale.fast),
                       value: away)
    }
}

// MARK: - The stand-in

/// The page's head and first lines, from the task's own data, laid out as
/// `TaskNoteHeadView` and the collapsed `TaskNoteSubtasksBlock` lay them out.
struct TaskPageStandInContent: Equatable {
    struct Row: Equatable, Identifiable {
        let id: UUID
        var title: String
        var isDone: Bool
    }

    var title: String
    var state: AtticTaskState
    var priority: AtticPriority
    var due: AtticTaskRowModel.Due?
    var tags: [String]
    var rows: [Row]

    var done: Int { rows.filter(\.isDone).count }
    var shownRows: ArraySlice<Row> { rows.prefix(TaskNotePageModel.collapsedRowLimit) }
    var hiddenCount: Int { max(0, rows.count - TaskNotePageModel.collapsedRowLimit) }
    var showsAdd: Bool { rows.count <= TaskNotePageModel.collapsedRowLimit }
    var countLabel: String {
        rows.isEmpty ? String(localized: "Subtasks") : String(localized: "Subtasks · \(done)/\(rows.count)")
    }

    @MainActor
    static func make(_ id: UUID, store: TaskStore) -> TaskPageStandInContent? {
        guard let task = store.listedTask(withID: id) else { return nil }
        let subtasks = task.doneLoggedAt != nil ? store.doneLogSubtasks(of: id) : store.subtasks(of: id)
        var due: AtticTaskRowModel.Due?
        if let day = task.dueDay {
            let calendar = Calendar.current
            due = TaskRowPresentation.due(day, today: DueDay(date: Date(), calendar: calendar),
                                          calendar: calendar, locale: .current)
        }
        return TaskPageStandInContent(
            title: task.title, state: TaskRowPresentation.state(task.status),
            priority: TaskRowPresentation.priority(task.priority), due: due, tags: task.tags,
            rows: subtasks.map { Row(id: $0.id, title: $0.title, isDone: $0.status == .done) })
    }
}

/// Where the opening row is, in the route host's space.
struct TaskPageStandInPose: Equatable {
    /// The title's leading edge and its line's centre.
    var titleX: CGFloat
    var lineMid: CGFloat
    var circleX: CGFloat
    var slotBottom: CGFloat

    @MainActor
    static func make(_ origin: AtticGrowOrigin, in view: NSView) -> TaskPageStandInPose? {
        guard let window = view.window, origin.windowNumber == 0 || origin.windowNumber == window.windowNumber
        else { return nil }
        let frame = view.convert(origin.frame, from: nil)
        let band = origin.titleBand ?? frame.height
        let slotX = frame.minX - AtticLayout.rowHighlightInset
        return TaskPageStandInPose(titleX: frame.minX + origin.titleInset, lineMid: frame.minY + band / 2,
                                   circleX: slotX + AtticLayout.circleX + AtticControlSize.statusCircle / 2,
                                   slotBottom: frame.maxY + (AtticLayout.rowPitch - AtticLayout.rowHighlightHeight) / 2)
    }
}

/// The page as it lands, drawn while the real one is not built yet: the
/// head (its title growing out of the row's), the details, the subtasks
/// unfolding top down, and Back and Aa rising in. `progress` runs on the
/// size spring: 0 is the row, 1 the page.
struct TaskPageStandIn: View, Animatable {
    var progress: CGFloat
    let content: TaskPageStandInContent
    let pose: TaskPageStandInPose
    let layout: PanelPageLayout
    let barShown: Bool
    let backTitle: String
    let back: () -> Void

    @Environment(\.atticDesign) private var design

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private typealias M = TaskNoteMetrics
    private typealias O = TaskPageOnePiece

    var body: some View {
        let p = progress
        let column = layout.chromeInsets.leading + AtticNoteMetrics.columnInset
        let headTop = layout.headerBottom + AtticNoteMetrics.titleTopGap
        let lineMid = headTop + M.titleLineHeight / 2
        let titleX = column + M.titleIndent
        let grow = AtticTextStyle.noteTitle.nsFont.pointSize / AtticTextStyle.taskTitle.nsFont.pointSize
        // The head's title: from the row's size and place to its own.
        let k = O.lerp(1 / grow, 1, p)
        let lineY = O.lerp(pose.lineMid, lineMid, p)
        let titleDX = O.lerp(pose.titleX, titleX, p) - titleX
        let titleDY = lineY - headTop - M.titleLineHeight / 2 * k
        let headIn = O.ramp(p, 0, 0.45)
        // The details and the block come from under the row.
        let from = pose.slotBottom
        GeometryReader { proxy in
            let headWidth = max(1, proxy.size.width - column * 2)
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    head(dx: titleDX, dy: titleDY, scale: k, opacity: headIn)
                    if content.due != nil || !content.tags.isEmpty {
                        details
                            .padding(.top, M.detailsGap)
                            .padding(.leading, M.titleIndent)
                            .offset(y: O.lerp(from - headTop - M.titleLineHeight, 0, p))
                            .opacity(O.ramp(p, 0.2, 0.75))
                    }
                    block
                        .padding(.top, M.headToBlock)
                        .mask(alignment: .top) {
                            Rectangle().scaleEffect(x: 1, y: max(0, min(1, p)), anchor: .top)
                        }
                        .offset(y: O.lerp(from - lineMid - M.titleLineHeight, 0, p))
                        .opacity(O.ramp(p, 0, 0.6))
                }
                .frame(width: headWidth, alignment: .topLeading)
                .offset(x: column, y: headTop)

                // The circle travels from the row's place to the head's.
                AtticStatusButton(state: content.state, priority: content.priority,
                                  subtasks: content.rows.isEmpty ? nil : (content.done, content.rows.count),
                                  isTabStop: false) {}
                    .allowsHitTesting(false)
                    .frame(width: AtticControlSize.minimumHitTarget, height: AtticControlSize.minimumHitTarget)
                    .offset(x: O.lerp(pose.circleX, column + AtticControlSize.statusCircle / 2, p) - AtticControlSize.minimumHitTarget / 2,
                            y: lineY - AtticControlSize.minimumHitTarget / 2)

                bar
                    .offset(y: O.lerp(24, 0, O.ramp(p, 0.25, 0.85)))
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .accessibilityHidden(true)
    }

    /// `TaskNoteHeadView`'s layout: the title on the row's column, the ⋯.
    private func head(dx: CGFloat, dy: CGFloat, scale: CGFloat, opacity: CGFloat) -> some View {
        let title = Text(verbatim: content.title)
            .font(Font(AtticTextStyle.noteTitle.nsFont))
            .foregroundColor(design.tokens.color(content.state == .done ? .helper : .heading))
        return ZStack(alignment: .topLeading) {
            Text("\(title)\(priorityText(content.priority))")
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: M.titleLineHeight, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .offset(x: dx, y: dy)
                .opacity(opacity)
                .padding(.leading, M.titleIndent)
                .padding(.trailing, M.titleTrailing)
                .frame(maxWidth: .infinity, alignment: .leading)
            AtticNoteMenuButton {}
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
                .offset(x: 4, y: -1)
                .opacity(opacity)
        }
    }

    private func priorityText(_ priority: AtticPriority) -> Text {
        let mark: String
        let ink: AtticInk
        switch priority {
        case .high: mark = "!!"; ink = .priorityMark
        case .medium: mark = "!"; ink = .helper
        case .low: mark = "↓"; ink = .helper
        case .none: return Text("")
        }
        return Text(verbatim: "  " + mark)
            .font(Font(AtticTextStyle.priorityMark.nsFont).weight(.bold))
            .foregroundColor(design.tokens.color(ink))
            .baselineOffset(1)
    }

    private var details: some View {
        HStack(spacing: M.detailsSpacing) {
            if let due = content.due { AtticDueText(due: due) }
            ForEach(content.tags, id: \.self) { tag in
                AtticText(verbatim: "#" + tag, style: .rowMeta, ink: .helper)
            }
        }
        .frame(height: M.detailsHeight, alignment: .leading)
        .lineLimit(1)
    }

    /// The collapsed `TaskNoteSubtasksBlock`: its label, the first three
    /// rows, then Add subtask or "N more…".
    private var block: some View {
        VStack(alignment: .leading, spacing: 0) {
            AtticText(verbatim: content.countLabel, style: .rowMeta, ink: .helper)
                .frame(height: M.blockHeader, alignment: .leading)
            ForEach(content.shownRows) { row in
                HStack(spacing: AtticSubtaskMetrics.titleGap) {
                    AtticSubtaskCheckbox(isDone: row.isDone)
                        .frame(width: AtticSubtaskMetrics.hitSize, height: AtticSubtaskMetrics.hitSize)
                        .padding(.horizontal, -(AtticSubtaskMetrics.hitSize - M.boxColumn) / 2)
                    AtticText(verbatim: row.title, style: .listBody, ink: row.isDone ? .helper : .body, truncates: true)
                    Spacer(minLength: 0)
                }
                .frame(height: M.rowHeight)
            }
            if content.showsAdd {
                HStack(spacing: AtticSubtaskMetrics.titleGap) {
                    AtticIcon(systemName: "plus", size: 11, weight: .medium, ink: .helper)
                        .frame(width: M.boxColumn)
                    AtticText("Add subtask", style: .listBody, ink: .helper)
                    Spacer(minLength: 0)
                }
                .frame(height: M.rowHeight)
            }
            if content.hiddenCount > 0 {
                AtticText(verbatim: String(localized: "\(content.hiddenCount) more…"), style: .controlLabel, ink: .helper)
                    .frame(height: M.rowHeight)
                    .padding(.leading, M.rowTextIndent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The page's bottom row: Back, and Aa on the right.
    private var bar: some View {
        AtticControlGroup {
            HStack(spacing: 0) {
                PanelControlFold(folded: !barShown, animation: { folded in
                    folded ? AtticMotionScale.easeOut(AtticMotionScale.fast)
                           : AtticMotionScale.easeOut(AtticMotionScale.standard).delay(0.06)
                }) {
                    AtticRaisedButton(systemName: "chevron.left", label: "Back", help: backTitle + "  (Esc)") { back() }
                        .accessibilityLabel(backTitle)
                }
                Spacer(minLength: AtticSpacing.s12)
                PanelControlFold(folded: !barShown, animation: { folded in
                    folded ? AtticMotionScale.easeOut(AtticMotionScale.fast)
                           : AtticMotionScale.easeOut(AtticMotionScale.standard).delay(0.06)
                }) {
                    AtticRaisedButton(systemName: "textformat", label: "Format", help: String(localized: "Format (⌘T)")) {}
                        .allowsHitTesting(false)
                }
            }
            .frame(height: AtticControlSize.panelButton.height)
        }
        .panelRowGivesWayToCard()
        .padding(.leading, layout.chromeInsets.leading)
        .padding(.trailing, layout.chromeInsets.trailing)
        .padding(.bottom, layout.chromeInsets.bottom)
    }
}

/// An NSView behind the route host: converts the row's window rectangle
/// into the host's space, and owns Escape while the stand-in is up.
struct TaskPageOnePieceProbe: NSViewRepresentable {
    @MainActor
    final class Box {
        weak var view: NSView?
        var keyMonitor: Any?

        /// Escape goes Back while the page is still the stand-in (no page
        /// is there yet to take it).
        func watchEscape(_ onEscape: @escaping () -> Bool) {
            stopWatchingEscape()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated {
                    guard event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                          let window = self?.view?.window, event.window === window else { return event }
                    return onEscape() ? nil : event
                }
            }
        }

        func stopWatchingEscape() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    let box: Box

    final class ProbeView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        box.view = view
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) { box.view = view }
}

/// One opening (or closing) of a task's page in one piece.
struct TaskPageOnePieceRun: Equatable {
    let taskID: UUID
    var content: TaskPageStandInContent
    var pose: TaskPageStandInPose
    var way: TaskPageMakeWay
    /// The target: true opening or open, false going back.
    var open = false
    /// The built page shows; the stand-in has given way to it.
    var handedOver = false
    /// Back has landed; the run ends once the page is gone.
    var landedBack = false
    var generation = 0

    /// What the list reads.
    var listWay: TaskPageMakeWay {
        var way = self.way
        way.open = open
        return way
    }

    @MainActor
    static func make(_ id: UUID, origin: AtticGrowOrigin, view: NSView, store: TaskStore,
                     layout: PanelPageLayout) -> TaskPageOnePieceRun? {
        guard origin.titleBand != nil, let pose = TaskPageStandInPose.make(origin, in: view),
              let content = TaskPageStandInContent.make(id, store: store) else { return nil }
        return TaskPageOnePieceRun(taskID: id, content: content, pose: pose,
                                   way: way(id, pose: pose, view: view, layout: layout))
    }

    @MainActor
    static func way(_ id: UUID, pose: TaskPageStandInPose, view: NSView, layout: PanelPageLayout) -> TaskPageMakeWay {
        TaskPageMakeWay(anchorID: id, anchorBottom: pose.slotBottom,
                        rise: TaskPageOnePiece.headLineMid(layout) - pose.lineMid,
                        push: max(120, view.bounds.height - pose.slotBottom))
    }
}
