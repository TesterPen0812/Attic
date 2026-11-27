import AppKit
import SwiftData
import SwiftUI

// MARK: - A task's page opens in one piece (Accepted 2026-11-25)

// Opening a task's page from a Tasks row is one motion on the size spring
// (drawn in Preview - settings at bottom, "Task page opens", one piece). Every
// part follows one progress, `p`, 0 at the row and 1 at the page, as the
// drawing's keyframe tracks do on its one spring (`tpOpen`):
//
// - the row's title travels to the head's first line, growing to the head's
//   size and fading by 0.45; the head's title comes from the row's line at the
//   row's size and is in by 0.45 (the two cross-fade as they travel);
// - the row's circle travels to the head's and fades over the whole motion;
//   the head's circle travels from the row's and is in by 0.3;
// - the rest of the row (date, ›, tags) moves 40 % of the rise by 0.35 while
//   it fades; the row's highlight fades by 0.4;
// - the rows above rise with the row, the rows below are pushed down (half
//   the push by 0.55), both gone by 0.55;
// - the details line comes from under the row (0.2 to 0.75); the subtasks and
//   the note unfold top down from under it, in by 0.6;
// - Now · Later · Done fades by 0.4; the tag bar, "+" and the agent's opener
//   drop 12 pt as they go; Back and Aa rise 12 pt between 0.25 and 0.85.
//
// Each part is a small `Animatable` modifier over `p`, so a frame runs those
// modifiers and nothing else: no text is laid out and nothing is built while
// it moves. The page's head and first lines are a stand-in drawn from the
// task's own data at the places the built page puts them. The real page is
// built once the spring has settled, under the stand-in, which gives way to
// it in one frame. Back runs every part backwards from where it is now.

enum TaskPageOnePiece {
    /// The route host's space: the list's lines and the stand-in read it.
    nonisolated static let space = "task-page-one-piece"

    /// The size spring (Lively: 0.28 s, bounce 0.12; about 0.39 s to settle).
    static var spring: Animation {
        .spring(duration: AtticMotionPreset.expand.duration, bounce: AtticMotionPreset.expand.bounce)
    }

    /// How far the bars drop and Back and Aa rise (the drawing's 24 px).
    nonisolated static let barTravel: CGFloat = 12
    /// The least the rows below are pushed (the drawing's 120 px).
    nonisolated static let leastPush: CGFloat = 60

    /// A line's middle in the route host's space, from its frame in the
    /// global space. The line is drawn in its tab's own host, where the
    /// route host's named space does not resolve: asked for it, SwiftUI gave
    /// the global frame (CI run 45914516669, `KeptContentHostTests`: 100
    /// where the space put it at 50). The global space is the same on both
    /// sides of the host, so the route host's top in it places the line.
    nonisolated static func lineMid(_ frameInGlobal: CGRect, spaceTop: CGFloat) -> CGFloat {
        frameInGlobal.midY - spaceTop
    }

    nonisolated static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    /// 0 before `from`, 1 after `to`, linear between (on the spring's progress).
    nonisolated static func ramp(_ p: CGFloat, _ from: CGFloat, _ to: CGFloat) -> CGFloat {
        min(1, max(0, (p - from) / (to - from)))
    }

    /// A keyframe track through (0, 0), (`at`, `mid`) and (1, 1), carried on
    /// past 1 (the spring's overshoot) along its last piece.
    nonisolated static func track(_ p: CGFloat, at: CGFloat, mid: CGFloat) -> CGFloat {
        p <= at ? mid * p / at : mid + (1 - mid) * (p - at) / (1 - at)
    }

    // The drawing's tracks, by part. Opacity is clamped; travel is not, so the
    // spring's small overshoot carries through as it does in the drawing.

    /// The rows above and below the opening row.
    nonisolated static func lineOpacity(_ p: CGFloat) -> Double { Double(1 - ramp(p, 0, 0.55)) }
    nonisolated static func linePush(_ p: CGFloat) -> CGFloat { track(p, at: 0.55, mid: 0.5) }
    /// The row's own title and circle, leaving.
    nonisolated static func rowTitleOpacity(_ p: CGFloat) -> Double { Double(1 - ramp(p, 0, 0.45)) }
    nonisolated static func rowCircleOpacity(_ p: CGFloat) -> Double { Double(1 - ramp(p, 0, 1)) }
    /// The rest of the row: 40 % of the rise by 0.35, gone there.
    nonisolated static func rowRestTravel(_ p: CGFloat) -> CGFloat { track(p, at: 0.35, mid: 0.4) }
    nonisolated static func rowRestOpacity(_ p: CGFloat) -> Double { Double(1 - ramp(p, 0, 0.35)) }
    nonisolated static func highlightOpacity(_ p: CGFloat) -> Double { Double(1 - ramp(p, 0, 0.4)) }
    /// The head's title and ⋯, and its circle, arriving.
    nonisolated static func headOpacity(_ p: CGFloat) -> Double { Double(ramp(p, 0, 0.45)) }
    nonisolated static func headCircleOpacity(_ p: CGFloat) -> Double { Double(ramp(p, 0, 0.3)) }
    nonisolated static func detailsOpacity(_ p: CGFloat) -> Double { Double(ramp(p, 0.2, 0.75)) }
    nonisolated static func bodyOpacity(_ p: CGFloat) -> Double { Double(ramp(p, 0, 0.6)) }
    /// Now · Later · Done (and the top row's other controls).
    nonisolated static func topOpacity(_ p: CGFloat) -> Double { Double(1 - ramp(p, 0, 0.4)) }
    /// The tag bar, "+" and the agent's opener.
    nonisolated static func barAway(_ p: CGFloat) -> CGFloat { ramp(p, 0, 0.45) }
    /// Back and Aa.
    nonisolated static func backBarIn(_ p: CGFloat) -> CGFloat { ramp(p, 0.25, 0.85) }
    /// Back and Aa's glass cannot follow an opacity (a glass group ignores
    /// one from outside), so it folds as the motion enters their part of it:
    /// in from 0.25 on the way to the page, away from 0.85 on the way back.
    nonisolated static func backBarShown(_ p: CGFloat, opening: Bool) -> Bool { p > (opening ? 0.25 : 0.85) }
}

// MARK: - Where things are

/// The opening row and the page's head, in the route host's space.
struct TaskPagePose: Equatable, Sendable {
    // The row, as laid out at the click.
    var rowTitleX: CGFloat
    var rowLineMid: CGFloat
    var rowCircleX: CGFloat
    var rowTop: CGFloat
    var rowBottom: CGFloat
    // The page's head, where the built page puts it.
    var headTitleX: CGFloat
    var headLineMid: CGFloat
    var headCircleX: CGFloat
    /// The route host's height (how far the rows below are pushed).
    var height: CGFloat
    /// The head's title size over the row's.
    var scale: CGFloat

    /// The row's title line to the head's first line (negative: up).
    var rise: CGFloat { headLineMid - rowLineMid }
    var titleShift: CGFloat { headTitleX - rowTitleX }
    var circleShift: CGFloat { headCircleX - rowCircleX }
    var push: CGFloat { max(TaskPageOnePiece.leastPush, height - rowBottom) }

    static var headScale: CGFloat {
        AtticTextStyle.noteTitle.nsFont.pointSize / AtticTextStyle.taskTitle.nsFont.pointSize
    }

    /// The head's places for a page laid out in `layout` (as
    /// `TaskNotePage` and `TaskNoteComposedHost` lay it out, unscrolled).
    static func head(_ layout: PanelPageLayout) -> (titleX: CGFloat, lineMid: CGFloat, circleX: CGFloat, top: CGFloat, column: CGFloat) {
        let column = layout.chromeInsets.leading + AtticNoteMetrics.columnInset
        let top = layout.headerBottom + AtticNoteMetrics.titleTopGap
        return (column + TaskNoteMetrics.titleIndent, top + TaskNoteMetrics.titleLineHeight / 2,
                column + AtticControlSize.statusCircle / 2, top, column)
    }

    /// The row's slot from its grow origin (window coordinates), in `view`'s
    /// flipped space, with the page's head from `layout`.
    @MainActor
    static func make(_ origin: AtticGrowOrigin, in view: NSView, layout: PanelPageLayout) -> TaskPagePose? {
        guard let window = view.window, origin.windowNumber == 0 || origin.windowNumber == window.windowNumber,
              let band = origin.titleBand else { return nil }
        let frame = view.convert(origin.frame, from: nil)
        let slotX = frame.minX - AtticLayout.rowHighlightInset
        let head = head(layout)
        return TaskPagePose(
            rowTitleX: frame.minX + origin.titleInset, rowLineMid: frame.minY + band / 2,
            rowCircleX: slotX + AtticLayout.circleX + AtticControlSize.statusCircle / 2,
            rowTop: frame.minY, rowBottom: frame.maxY,
            headTitleX: head.titleX, headLineMid: head.lineMid, headCircleX: head.circleX,
            height: view.bounds.height, scale: headScale)
    }
}

/// What the list reads while a task's page opens over it.
struct TaskPageMakeWay: Equatable, Sendable {
    var anchorID: UUID
    var pose: TaskPagePose
    /// 0 at the row, 1 at the page (animated on the size spring).
    var progress: CGFloat
    /// The route host's top in the global space (`TaskPageMotion.spaceTop`).
    var spaceTop: CGFloat = 0
}

extension EnvironmentValues {
    /// The route host's motion (one object for the page's life): the list's
    /// lines, the opening row and Tasks' top row read its progress, so a turn
    /// of the motion reaches them and nothing else in the page.
    @Entry var taskPageMotion: TaskPageMotion? = nil
    /// What a Tasks list's lines draw: set at the list's root, in the list's
    /// own host (`TaskPageListFollows`), and nil in every list but the one
    /// the page opened from.
    @Entry var taskPageWay: TaskPageMakeWay? = nil
    /// Set only on the row whose page is opening: its parts travel.
    @Entry var taskPageRowLeaving: TaskPageMakeWay? = nil
    /// Back and Aa are in (set by the stand-in's bar as the motion passes
    /// their part of it).
    @Entry var taskPageBarShown = true
}

// MARK: - The list makes way

/// Every line of a Tasks list (applied through a Group, so to each row,
/// header and line): the lines above the opening row rise with it, the lines
/// below are pushed down, all gone by 0.55. The opening row's own line stays;
/// its parts move (`TaskPageRowPart`). Offset and opacity only, drawn and
/// never laid out, so tab, scroll and selection are exactly as they were.
struct TaskPageMakeWayLine: ViewModifier {
    @Environment(\.taskPageWay) private var way

    func body(content: Content) -> some View {
        content.modifier(TaskPageLineEffect(progress: way?.progress ?? 0, pose: way?.pose, spaceTop: way?.spaceTop ?? 0))
    }
}

/// A Tasks list's root, in the list's own host: the one reader of the motion
/// in that list. Its lines, rows and highlight draw the value it hands them.
///
/// Every built tab keeps its list in a host of its own, and a host that is
/// not drawn runs its readers but never moves a spring on. A hidden tab that
/// read the motion started a spring it never finished, so the motion's
/// completion, which waits for every spring it started, never came and Back
/// never landed (CI run 45890021290, variant H: `line host=1511 drawn=false
/// ... last=1.000` and no completion; with the lists' readers off it
/// landed). So only the list the page opened from follows the motion.
///
/// It reads the progress and nothing else that an opening writes before its
/// spring starts: a reader told of the click's own writes first took the
/// spring's change with them, unanimated, and its lines jumped (the same
/// run: the drawn list's lines drew 1.000 first on every opening).
struct TaskPageListFollows: ViewModifier {
    let tab: TasksTab
    @Environment(\.taskPageMotion) private var motion

    func body(content: Content) -> some View {
        content.environment(\.taskPageWay, way)
    }

    private var way: TaskPageMakeWay? {
        guard let motion, motion.listTab == tab else { return nil }
        let progress = motion.progress
        guard let place = motion.place else { return nil }
        return TaskPageMakeWay(anchorID: place.anchorID, pose: place.pose, progress: progress, spaceTop: motion.spaceTop)
    }
}

/// Diagnosis (DEBUG): a view's identity across Back. A new identity takes
/// a new serial (its state is new) and appears again.
struct TaskPageIdentityStamp: ViewModifier {
    let name: String
    #if DEBUG
    @State private var serial = TaskPageIdentityStamp.next()
    @MainActor private static var count = 0
    @MainActor private static func next() -> Int { count += 1; return count }
    #endif

    func body(content: Content) -> some View {
        #if DEBUG
        let _ = TaskPageMotion.mark("stamp \(name)")
        content
            .onAppear { [serial, name] in TaskPageMotion.mark("appear \(name) #\(serial)") }
            .onDisappear { [serial, name] in TaskPageMotion.mark("disappear \(name) #\(serial)") }
        #else
        content
        #endif
    }
}

/// Tells the motion which Tasks tab is shown, as it changes (long before a
/// click, so the lists have taken it by then).
struct TaskPageListTab: ViewModifier {
    let tab: TasksTab
    @Environment(\.taskPageMotion) private var motion

    func body(content: Content) -> some View {
        content.onChange(of: tab, initial: true) { _, tab in
            if motion?.listTab != tab { motion?.listTab = tab }
        }
    }
}

/// Whether the Tasks pager draws its shown list under a task's page: from
/// Back's first frame, so the list runs back with the page instead of
/// starting when the route has closed.
struct TaskPageDrawsList<Content: View>: View {
    @Environment(\.taskPageMotion) private var motion
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        // Told only when Back starts (in the spring's transaction, so the
        // list's host takes its root under it) and when a page takes over
        // (still). An opening
        // that ended leaves the flag as it is (writing it would run the
        // pager again for nothing), so it counts only while one is under
        // way, which is read here without being observed.
        content((motion?.drawsListUnderPage ?? false) && motion?.place != nil)
    }
}

private struct TaskPageLineEffect: ViewModifier, Animatable {
    var progress: CGFloat
    let pose: TaskPagePose?
    let spaceTop: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = progress, pose = pose, spaceTop = spaceTop
        #if DEBUG
        let _ = TaskPageMotion.lineDrew(p, following: pose != nil)
        #endif
        content.visualEffect { effect, proxy in
            guard let pose, p != 0 else { return effect.offset(y: 0).opacity(1) }
            let mid = TaskPageOnePiece.lineMid(proxy.frame(in: .global), spaceTop: spaceTop)
            if mid >= pose.rowTop, mid <= pose.rowBottom { return effect.offset(y: 0).opacity(1) }
            let dy = mid < pose.rowTop ? pose.rise * p : pose.push * TaskPageOnePiece.linePush(p)
            return effect.offset(y: dy).opacity(TaskPageOnePiece.lineOpacity(p))
        }
    }
}

/// The opening row's cell: tells its row it is the one leaving.
struct TaskPageRowLeaving: ViewModifier {
    let id: UUID
    @Environment(\.taskPageWay) private var way

    func body(content: Content) -> some View {
        content.environment(\.taskPageRowLeaving, way?.anchorID == id ? way : nil)
    }
}

/// The parts of the opening row.
enum TaskPageRowPartKind: Sendable { case title, circle, rest }

/// A part of the opening row (identity on every other row): the title travels
/// to the head's first line and grows to the head's size, fading by 0.45; the
/// circle travels to the head's, fading over the whole; the rest moves 40 % of
/// the rise by 0.35 as it fades.
struct TaskPageRowPart: ViewModifier {
    let kind: TaskPageRowPartKind
    @Environment(\.taskPageRowLeaving) private var leaving

    func body(content: Content) -> some View {
        content.modifier(TaskPageRowPartEffect(kind: kind, progress: leaving?.progress ?? 0, pose: leaving?.pose))
    }
}

private struct TaskPageRowPartEffect: ViewModifier, Animatable {
    let kind: TaskPageRowPartKind
    var progress: CGFloat
    let pose: TaskPagePose?

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = pose == nil ? 0 : progress
        let pose = pose ?? .zero
        switch kind {
        case .title:
            content
                .scaleEffect(TaskPageOnePiece.lerp(1, pose.scale, p), anchor: .leading)
                .offset(x: pose.titleShift * p, y: pose.rise * p)
                .opacity(TaskPageOnePiece.rowTitleOpacity(p))
        case .circle:
            content
                .offset(x: pose.circleShift * p, y: pose.rise * p)
                .opacity(TaskPageOnePiece.rowCircleOpacity(p))
        case .rest:
            content
                .offset(y: pose.rise * TaskPageOnePiece.rowRestTravel(p))
                .opacity(TaskPageOnePiece.rowRestOpacity(p))
        }
    }
}

extension TaskPagePose {
    static let zero = TaskPagePose(rowTitleX: 0, rowLineMid: 0, rowCircleX: 0, rowTop: 0, rowBottom: 0,
                                   headTitleX: 0, headLineMid: 0, headCircleX: 0, height: 0, scale: 1)
}

/// The selection's highlight under the opening row fades by 0.4.
struct TaskPageHighlightFade: ViewModifier {
    @Environment(\.taskPageWay) private var way

    func body(content: Content) -> some View {
        content.modifier(TaskPageFadeEffect(progress: way?.progress ?? 0, track: .highlight))
    }
}

/// Tasks' own top row (Now · Later · Done, ••• and Find) fades by 0.4.
struct TaskPageTopRowFade: ViewModifier {
    @Environment(\.taskPageMotion) private var motion

    func body(content: Content) -> some View {
        let way = motion?.way
        return content
            .modifier(TaskPageFadeEffect(progress: way?.progress ?? 0, track: .top))
            .allowsHitTesting(way == nil)
    }
}

enum TaskPageFadeTrack: Sendable { case highlight, top }

private struct TaskPageFadeEffect: ViewModifier, Animatable {
    var progress: CGFloat
    let track: TaskPageFadeTrack

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        switch track {
        case .highlight: content.opacity(TaskPageOnePiece.highlightOpacity(progress))
        case .top: content.opacity(TaskPageOnePiece.topOpacity(progress))
        }
    }
}

/// The shell's tag bar, "+" and the agent's opener drop 12 pt as they give
/// way (their glass fades through the fold, which a glass group needs).
struct TaskPageBarDrop: ViewModifier, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.offset(y: TaskPageOnePiece.barTravel * TaskPageOnePiece.barAway(progress))
    }
}

// MARK: - The stand-in

/// The page's head and first lines, from the task's own data, laid out as
/// `TaskNoteHeadView`, the collapsed `TaskNoteSubtasksBlock` and the writing
/// lay them out.
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
    /// The first lines of the task's own note (nil: it has none).
    var writing: String?

    var done: Int { rows.filter(\.isDone).count }
    var shownRows: ArraySlice<Row> { rows.prefix(TaskNotePageModel.collapsedRowLimit) }
    var hiddenCount: Int { max(0, rows.count - TaskNotePageModel.collapsedRowLimit) }
    var showsAdd: Bool { rows.count <= TaskNotePageModel.collapsedRowLimit }
    var countLabel: String {
        rows.isEmpty ? String(localized: "Subtasks") : String(localized: "Subtasks · \(done)/\(rows.count)")
    }

    /// The writing's first lines are enough: the page shows no more of it
    /// before it is built (the panel is at most a screen tall).
    static let writingLimit = 1_200

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
            rows: subtasks.map { Row(id: $0.id, title: $0.title, isDone: $0.status == .done) },
            writing: ownNoteBody(id, in: store.container.mainContext))
    }

    /// The task's own note's text (its body: the title is the head's).
    @MainActor
    static func ownNoteBody(_ taskID: UUID, in context: ModelContext) -> String? {
        var fetch = FetchDescriptor<NoteItem>(predicate: #Predicate { $0.taskID == taskID && $0.deletedAt == nil })
        fetch.fetchLimit = 1
        guard let note = try? context.fetch(fetch).first else { return nil }
        let body = note.body
        return body.count > writingLimit ? String(body.prefix(writingLimit)) : body
    }
}

/// The page as it lands, drawn while the real one is not built yet: built
/// once per opening, then only its parts' modifiers run as `progress` moves.
struct TaskPageStandIn: View {
    let progress: CGFloat
    let content: TaskPageStandInContent
    let pose: TaskPagePose
    let layout: PanelPageLayout
    /// Towards the page (Back and Aa come in) or back into the row.
    let opening: Bool
    /// The built page has it: the stand-in stays in, unseen and with no
    /// glass, so Back runs it from the page's places (a stand-in put back in
    /// on Back drew the row's places at once, CI run 45858549846).
    var parked = false
    let backTitle: String
    let back: () -> Void

    @Environment(\.atticDesign) private var design

    private typealias M = TaskNoteMetrics

    var body: some View {
        #if DEBUG
        let _ = TaskPageMotion.mark("body stand-in parked=\(parked)")
        #endif
        let head = TaskPagePose.head(layout)
        ZStack(alignment: .topLeading) {
            GeometryReader { proxy in
                let width = max(1, proxy.size.width - head.column * 2)
                VStack(alignment: .leading, spacing: 0) {
                    headTitle
                        .modifier(TaskPageStandInPart(part: .head, progress: progress, pose: pose, top: head.top))
                    if content.due != nil || !content.tags.isEmpty {
                        details
                            .padding(.top, M.detailsGap)
                            .padding(.leading, M.titleIndent)
                            .modifier(TaskPageStandInPart(part: .details, progress: progress, pose: pose, top: head.top))
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        block
                        writing
                            .padding(.top, M.blockToWriting)
                    }
                    .padding(.top, M.headToBlock)
                    .modifier(TaskPageStandInPart(part: .body, progress: progress, pose: pose, top: head.top))
                }
                .frame(width: width, alignment: .topLeading)
                .offset(x: head.column, y: head.top)

                // The head's circle travels from the row's.
                AtticStatusButton(state: content.state, priority: content.priority,
                                  subtasks: content.rows.isEmpty ? nil : (content.done, content.rows.count),
                                  isTabStop: false) {}
                    .allowsHitTesting(false)
                    .frame(width: AtticControlSize.minimumHitTarget, height: AtticControlSize.minimumHitTarget)
                    .offset(x: head.circleX - AtticControlSize.minimumHitTarget / 2,
                            y: head.lineMid - AtticControlSize.minimumHitTarget / 2)
                    .modifier(TaskPageStandInPart(part: .circle, progress: progress, pose: pose, top: head.top))
            }
            bar
                .modifier(TaskPageStandInPart(part: .bar, progress: progress, pose: pose, top: head.top, opening: opening))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }

    /// The title, its mark and the note's ⋯, as `TaskNoteHeadView` draws them.
    private var headTitle: some View {
        let title = Text(verbatim: content.title)
            .font(Font(AtticTextStyle.noteTitle.nsFont))
            .foregroundColor(design.tokens.color(content.state == .done ? .helper : .heading))
        return ZStack(alignment: .topLeading) {
            Text("\(title)\(priorityText(content.priority))")
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: M.titleLineHeight, alignment: .topLeading)
                .padding(.leading, M.titleIndent)
                .padding(.trailing, M.titleTrailing)
                .frame(maxWidth: .infinity, alignment: .leading)
            AtticNoteMenuButton {}
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
                .offset(x: 4, y: -1)
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

    /// The writing's first lines on the note's column, in the note's body
    /// type (the built page's text view draws the same text there).
    @ViewBuilder
    private var writing: some View {
        if let text = content.writing, !text.isEmpty {
            let role = AtticNoteType.body
            let font = AtticTextStyle.noteBody.nsFont
            Text(verbatim: text)
                .font(Font(font))
                .foregroundColor(design.tokens.color(.body))
                .lineSpacing(max(0, role.lineHeight - (font.ascender - font.descender + font.leading)))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// Back and Aa, as the page's bottom row draws them.
    @ViewBuilder private var bar: some View {
        if parked {
            // No glass while unseen (a glass group ignores an outside opacity).
            Color.clear.frame(height: AtticControlSize.panelButton.height)
        } else {
            glassBar
        }
    }

    private var glassBar: some View {
        AtticControlGroup {
            HStack(spacing: 0) {
                TaskPageBarFold {
                    AtticRaisedButton(systemName: "chevron.left", label: "Back", help: backTitle + "  (Esc)") { back() }
                        .accessibilityLabel(backTitle)
                }
                Spacer(minLength: AtticSpacing.s12)
                if content.writing != nil {
                    TaskPageBarFold {
                        AtticRaisedButton(systemName: "textformat", label: "Format", help: String(localized: "Format (⌘T)")) {}
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: AtticControlSize.panelButton.height)
        }
        .panelRowGivesWayToCard()
        .padding(.leading, layout.chromeInsets.leading)
        .padding(.trailing, layout.chromeInsets.trailing)
        .padding(.bottom, layout.chromeInsets.bottom)
    }

    /// Back and Aa's fold once the motion reaches their part of it: each
    /// about as long as the spring takes over that part.
    static func barAnimation(folded: Bool, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        return folded ? .spring(duration: 0.12, bounce: 0) : .spring(duration: 0.14, bounce: 0)
    }
}

/// Back or Aa in the stand-in's bar: folds (its glass with it) as the motion
/// passes its part (`taskPageBarShown`). It starts as it is first drawn, so
/// on Back it is there in the first frame, in the built page's buttons'
/// place, and folds away from there (it was put in already folded, and the
/// buttons vanished at once).
private struct TaskPageBarFold<Content: View>: View {
    @Environment(\.taskPageBarShown) private var shown
    @Environment(\.atticDesign) private var design
    @ViewBuilder let content: () -> Content

    var body: some View {
        TaskPageBarFoldBody(shown: shown, reduceMotion: design.reduceMotion, content: content)
    }
}

private struct TaskPageBarFoldBody<Content: View>: View {
    let shown: Bool
    let reduceMotion: Bool
    let content: () -> Content
    @State private var away: Bool
    @State private var gone: Bool

    init(shown: Bool, reduceMotion: Bool, content: @escaping () -> Content) {
        self.shown = shown
        self.reduceMotion = reduceMotion
        self.content = content
        _away = State(initialValue: !shown)
        _gone = State(initialValue: !shown)
    }

    var body: some View {
        content()
            .environment(\.atticControlAway, away)
            .environment(\.atticControlGone, gone)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .animation(TaskPageStandIn.barAnimation(folded: !shown, reduceMotion: reduceMotion), value: shown)
            .onChange(of: shown) { _, shown in fold(!shown) }
    }

    /// As `PanelControlFold`: the glass fades with the button, then goes.
    private func fold(_ folded: Bool) {
        guard folded != away else { return }
        let animation = TaskPageStandIn.barAnimation(folded: folded, reduceMotion: reduceMotion)
        if folded {
            guard let animation else {
                away = true
                gone = true
                return
            }
            withAnimation(animation) { away = true } completion: { if away { gone = true } }
        } else {
            gone = false
            withAnimation(animation) { away = false }
        }
    }
}

enum TaskPageStandInPartKind: Sendable { case head, circle, details, body, bar }

/// One part of the stand-in on `progress` (render only: offsets, scale,
/// opacity and a mask).
private struct TaskPageStandInPart: ViewModifier, Animatable {
    let part: TaskPageStandInPartKind
    var progress: CGFloat
    let pose: TaskPagePose
    /// The head's top (the head's title is scaled from there).
    let top: CGFloat
    /// The bar's: towards the page or back.
    let opening: Bool

    init(part: TaskPageStandInPartKind, progress: CGFloat, pose: TaskPagePose, top: CGFloat, opening: Bool = true) {
        self.part = part
        self.progress = progress
        self.pose = pose
        self.top = top
        self.opening = opening
    }

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = progress
        let O = TaskPageOnePiece.self
        #if DEBUG
        let _ = part == .head ? TaskPageMotion.drew("S", p) : ()
        #endif
        switch part {
        case .head:
            // From the row's line at the row's size to the head's: the first
            // line's centre travels on a straight line while the scale grows.
            let k = O.lerp(1 / pose.scale, 1, p)
            let lineMid = O.lerp(pose.rowLineMid, pose.headLineMid, p)
            let half = TaskNoteMetrics.titleLineHeight / 2
            content
                .scaleEffect(k, anchor: .topLeading)
                // Scaled from its top-leading corner, the title's own start
                // (after the circle's column) moves in by the column's share.
                .offset(x: -pose.titleShift * (1 - p) + TaskNoteMetrics.titleIndent * (1 - k),
                        y: lineMid - top - half * k)
                .opacity(O.headOpacity(p))
        case .circle:
            content
                .offset(x: -pose.circleShift * (1 - p), y: -pose.rise * (1 - p))
                .opacity(O.headCircleOpacity(p))
        case .details:
            content
                .offset(y: (pose.rowBottom - pose.headLineMid) * (1 - p))
                .opacity(O.detailsOpacity(p))
        case .body:
            content
                .mask(alignment: .top) {
                    Rectangle().scaleEffect(x: 1, y: max(0, min(1, p)), anchor: .top)
                }
                .offset(y: (pose.rowBottom - pose.headLineMid) * (1 - p))
                .opacity(O.bodyOpacity(p))
        case .bar:
            content
                .environment(\.taskPageBarShown, O.backBarShown(p, opening: opening))
                .offset(y: TaskPageOnePiece.barTravel * (1 - O.backBarIn(p)))
        }
    }
}

// MARK: - The route host's probe

/// The route host's own view: converts the row's window frame into the host's
/// space, and watches Escape while the stand-in is the page (the built page's
/// editor owns Escape once it is there).
struct TaskPageOnePieceProbe: NSViewRepresentable {
    @MainActor
    final class Box {
        weak var view: NSView?
        var keyMonitor: Any?

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

// MARK: - One opening

/// One opening in one piece, from the click until Back has landed. One
/// object for the route host's life; its parts are observed apart, so the
/// progress reaches only what moves and the host itself redraws only when
/// the opening starts, hands over and ends.
@MainActor
@Observable
final class TaskPageMotion {
    /// The task whose page is opening, or nil.
    private(set) var taskID: UUID?
    private(set) var content: TaskPageStandInContent?
    private(set) var pose: TaskPagePose?
    /// 0 at the row, 1 at the page (animated on the size spring).
    var progress: CGFloat = 0
    /// Towards the page (true) or back into the row.
    var open = false
    /// The built page has taken over from the stand-in.
    var handedOver = false
    /// Back found no row to go into: the stand-in fades as it goes.
    var rowGone = false
    /// The Tasks tab shown: only its list follows the motion (`TaskPageListFollows`).
    var listTab: TasksTab?
    /// The pager draws its shown list under the page (from Back's start
    /// until the next page has taken over).
    var drawsListUnderPage = false
    /// The row and the head for the list, read without being observed: the
    /// list's readers are told of the progress only (`TaskPageListFollows`).
    @ObservationIgnored private(set) var place: (anchorID: UUID, pose: TaskPagePose)?
    /// The route host's top in the global space, where the list's lines find
    /// their place (`TaskPageOnePiece.lineMid`); kept by the route host.
    @ObservationIgnored var spaceTop: CGFloat = 0
    /// Each turn of the motion; a landing from an older one is ignored.
    @ObservationIgnored var generation = 0
    /// The motion is back at the row while the route is still closing.
    @ObservationIgnored var landedBack = false
    /// Waiting for the spring to settle before the page is built.
    @ObservationIgnored private var landingWaiters: [CheckedContinuation<Bool, Never>] = []

    var isActive: Bool { taskID != nil }

    /// What the list reads (nil while no page opens in one piece).
    var way: TaskPageMakeWay? {
        guard let taskID, let pose else { return nil }
        return TaskPageMakeWay(anchorID: taskID, pose: pose, progress: progress)
    }

    #if DEBUG
    /// Tests: the last motion that began, and how many began (nil and 0 in
    /// production builds, which leave this out).
    static weak var currentForTesting: TaskPageMotion?
    static var beginsForTesting = 0
    /// What the route did, in order, for a failing test to print.
    static var traceForTesting: [String] = []
    /// What the list's lines drew since the last turn began, in order.
    static var lineDrawsForTesting: [CGFloat] = []
    static func lineDrew(_ p: CGFloat, following: Bool) {
        if lineDrawsForTesting.last != p, lineDrawsForTesting.count < 512 { lineDrawsForTesting.append(p) }
        // The log keeps the list that follows the motion only.
        if following { drew("L", p) }
    }
    /// Diagnosis of Back's and Open's first frames: named work with times,
    /// only while a test turns it on.
    static var timingForTesting = false
    static var timeLogForTesting: [(time: CFTimeInterval, what: String)] = []
    static func mark(_ what: @autoclosure () -> String) {
        guard timingForTesting, timeLogForTesting.count < 4000 else { return }
        timeLogForTesting.append((CACurrentMediaTime(), what()))
    }
    /// The page opens as before (the grow), not in one piece.
    static var onePieceOffForTesting = false
    /// What the stand-in ("S", its head) and the list's lines ("L") drew,
    /// in order, with the time: Back's list is judged against the stand-in.
    static var drawLogForTesting: [(time: CFTimeInterval, kind: Character, p: CGFloat)] = []
    static func drew(_ kind: Character, _ p: CGFloat) {
        if let last = drawLogForTesting.last(where: { $0.kind == kind }), last.p == p { return }
        if drawLogForTesting.count < 1024 { drawLogForTesting.append((CACurrentMediaTime(), kind, p)) }
    }
    #endif

    /// DEBUG only: one line of the opening's history (tests print it).
    func trace(_ event: @autoclosure () -> String) {
        #if DEBUG
        Self.traceForTesting.append(String(format: "%.3f ", CACurrentMediaTime()) + event()
            + " open=\(open) p=\(progress) handed=\(handedOver) back=\(landedBack) gen=\(generation)")
        if Self.traceForTesting.count > 400 { Self.traceForTesting.removeFirst(100) }
        #endif
    }

    func begin(_ id: UUID, content: TaskPageStandInContent, pose: TaskPagePose) {
        #if DEBUG
        Self.currentForTesting = self
        Self.beginsForTesting += 1
        #endif
        taskID = id
        self.content = content
        self.pose = pose
        place = (id, pose)
        // A landing still due from the motion this one replaced is ignored.
        generation &+= 1
        // Not written when it is 0 already: the list's readers are told of
        // the spring's change first, never of the click's.
        if progress != 0 { progress = 0 }
        open = false
        handedOver = false
        rowGone = false
        landedBack = false
    }

    /// Back finds the row again (the list may have scrolled or changed).
    func retarget(content: TaskPageStandInContent?, pose: TaskPagePose?) {
        if let content, content != self.content { self.content = content }
        if let pose, pose != self.pose { self.pose = pose }
        if let pose, let taskID { place = (taskID, pose) }
    }

    func end() {
        taskID = nil
        content = nil
        pose = nil
        place = nil
        if progress != 0 { progress = 0 }
        open = false
        handedOver = false
        rowGone = false
        landedBack = false
        landed(false)
    }

    /// The page may be built: true once the spring towards it has settled,
    /// false when the opening turned back or ended first.
    func waitForLanding() async -> Bool {
        if open, progress == 1, !landingPending { return true }
        return await withCheckedContinuation { landingWaiters.append($0) }
    }

    /// The spring towards the page is still running.
    @ObservationIgnored var landingPending = false

    func landed(_ atPage: Bool) {
        landingPending = false
        let waiters = landingWaiters
        landingWaiters = []
        waiters.forEach { $0.resume(returning: atPage) }
    }
}

/// The stand-in while a page opens in one piece and until the built page
/// takes over; again from Back until the row has it back.
struct TaskPageOnePieceLayer: View {
    let motion: TaskPageMotion
    let layout: PanelPageLayout
    let backTitle: String
    /// The stand-in is in: the spring may start from where it is.
    let onAppear: () -> Void
    let back: () -> Void

    var body: some View {
        // In from the click until Back has landed: under the built page it is
        // parked (unseen, untouchable), so every part keeps a drawn value for
        // Back to run from.
        if motion.isActive, let content = motion.content, let pose = motion.pose {
            let parked = motion.handedOver
            TaskPageStandIn(progress: motion.progress, content: content, pose: pose, layout: layout,
                            opening: motion.open, parked: parked, backTitle: backTitle, back: back)
                // Back with the row gone: the page fades as the list comes back.
                .opacity(parked ? 0 : motion.rowGone ? Double(max(0, min(1, motion.progress))) : 1)
                .allowsHitTesting(!parked)
                .accessibilityHidden(parked)
                .transition(.identity)
                .onAppear(perform: onAppear)
                // A stand-in of its own for each task: another task opened
                // while one is still moving comes in fresh at its own row,
                // and its coming in starts its spring. Kept as one view, it
                // never appeared again, its motion never ran, and the first
                // one's landing let its page in at 0 (CI run 45914516669:
                // "end ... gen=1" then "handedOver ... p=0.0", no turn).
                .id(motion.taskID)
        }
    }
}
