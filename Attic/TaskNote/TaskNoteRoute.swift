import Combine
import SwiftUI

#if DEBUG
/// Test seam (NotesUndoMirrorCountGuardTests): how many times each page's
/// route host has run its body. A generic view holds no static storage.
@MainActor
enum TaskNoteRouteHostCounts {
    static var bodyEvaluations: [PanelPage: Int] = [:]
}
#endif

/// The task page's route on one panel page (UX plan § 5.3–5.4): the page
/// opens over its origin and Back returns there exactly as it was left.
///
/// Notes replaces its editor with the page (one live editor, OD-1). Tasks
/// keeps its list built under the page, covered and inert, so its tab,
/// scroll, selection and anchor row are all still there after Back.
struct TaskNoteRouteHost<Origin: View>: View {
    let page: PanelPage
    @ObservedObject var noteStore: NoteStore
    let taskStore: TaskStore
    @ObservedObject var noteDraft: NoteDraftController
    let uiState: PanelUIState
    let layout: PanelPageLayout
    /// Notes has restored its session (the page opens only after).
    let isReady: Bool
    @ViewBuilder let origin: (_ covered: Bool) -> Origin

    @Environment(\.atticDesign) private var design
    /// The shell's shared bars give way while a task's page covers this one.
    @Environment(\.panelSharedChrome) private var sharedChrome
    @State private var presentedTaskID: UUID?
    @State private var taskRouteGeneration = 0
    @State private var routeStateRevision = 0
    /// The page grows out of its row and shrinks back into it (Accepted
    /// 2026-11-13): it starts on the click, while the page builds behind.
    @State private var grow = AtticGrowState()
    @State private var growStartedAt: CFTimeInterval = 0
    /// Opening from a Tasks row, in one piece (Accepted 2026-11-25): the
    /// row becomes the page's head on the size spring (`TaskPageOnePiece`).
    @State private var onePiece: TaskPageOnePieceRun?
    @State private var onePieceProgress: CGFloat = 0
    /// The stand-in fades instead when Back finds no row to go into.
    @State private var onePieceFade: Double = 1
    @State private var onePieceProbe = TaskPageOnePieceProbe.Box()

    /// The route this page serves: only a page opened from here.
    private var requestedID: UUID? { uiState.taskNoteOrigin == page ? uiState.openTaskNoteID : nil }

    // A remounted section still shows its retained owner during a handoff.
    private var displayedTaskID: UUID? {
        presentedTaskID ?? (uiState.taskNoteOrigin == page ? noteDraft.pages.taskNotePresenter?.taskID : nil)
    }

    var body: some View {
        #if DEBUG
        let _ = TaskNoteRouteHostCounts.bodyEvaluations[page, default: 0] += 1
        #endif
        let _ = routeStateRevision
        let shown = isReady ? displayedTaskID : nil
        let looks = Self.looks(grow, shown: shown != nil)
        let one = onePiece
        // One piece: the built page shows once the stand-in gives way to it.
        let pageShows = one.map(\.handedOver) ?? looks.destinationShows
        ZStack {
            if page == .notes {
                // Notes: the page replaces the editor (one live editor).
                if shown == nil {
                    origin(false)
                        .opacity(looks.originShows ? 1 : 0)
                        .animation(grow.originAnimation(showing: looks.originShows), value: looks.originShows)
                        .allowsHitTesting(looks.originCurrent)
                        .transition(.asymmetric(insertion: .opacity.animation(grow.originAnimation(showing: true)),
                                                removal: .identity))
                }
            } else {
                origin(shown != nil || one?.open == true)
                    .modifier(PanelPageVisibility(isCurrent: one.map { !$0.open } ?? looks.originCurrent,
                                                  restingOffset: 0, disablesWhenHidden: false,
                                                  opacityOverride: one.map { .init(shows: !$0.handedOver, animation: nil) }
                                                    ?? (grow.style == .instant ? nil
                                                        : .init(shows: looks.originShows,
                                                                animation: grow.originAnimation(showing: looks.originShows)))))
                    .environment(\.taskPageMakeWay, one?.listWay)
            }
            if let taskID = shown {
                TaskNotePageContainer(taskID: taskID, tasks: taskStore, controller: noteDraft.pages,
                                      noteStore: noteStore, layout: layout,
                                      backTitle: uiState.taskNoteBackTitle,
                                      onOpenInWindow: { openInWindow(taskID) },
                                      onLeaving: { leaving in growBack(taskID, leaving: leaving) }) {
                    Self.closeRoute(taskID, uiState: uiState, controller: noteDraft.pages)
                }
                // The page's own top row is this page's (its Find takes it, N4 B).
                .environment(\.panelTopRowPage, page)
                .opacity(pageShows ? 1 : 0)
                .animation(one != nil ? nil : grow.destinationAnimation(showing: pageShows), value: pageShows)
                .allowsHitTesting(pageShows)
                .accessibilityHidden(!pageShows)
                .transition(.asymmetric(insertion: one != nil ? .identity : .opacity.animation(pageArrival), removal: .identity))
                .id("\(taskID)-\(taskRouteGeneration)")
            }
            if let one, !one.handedOver {
                // The head and first lines from the row's data, from the
                // click's first frame, while the real page is not built.
                TaskPageStandIn(progress: onePieceProgress, content: one.content, pose: one.pose, layout: layout,
                                barShown: one.open, backTitle: uiState.taskNoteBackTitle) {
                    Self.closeRoute(one.taskID, uiState: uiState, controller: noteDraft.pages)
                }
                .opacity(onePieceFade)
                .zIndex(3)
                .transition(.identity)
            }
            AtticGrowLayer(state: grow, onFinish: { $grow.finish($0) })
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .zIndex(2)
        }
        .coordinateSpace(.named(TaskPageOnePiece.space))
        .background(TaskPageOnePieceProbe(box: onePieceProbe).accessibilityHidden(true))
        .onChange(of: requestedID, initial: true) { old, new in growRoute(from: old, to: new) }
        // One piece: the bars give way on the click and come back on Back's,
        // on the same motion.
        .onChange(of: one?.open ?? (shown != nil), initial: true) { _, covered in
            sharedChrome?.setCovered(covered, page: page, animated: onePiece != nil)
        }
        .onChange(of: shown == nil) { _, gone in if gone, onePiece?.landedBack == true { endOnePiece() } }
        .onDisappear {
            sharedChrome?.setCovered(false, page: page)
            endOnePiece()
        }
        .onReceive(uiState.$openTaskNoteID.dropFirst()) { _ in routeStateRevision &+= 1 }
        .onReceive(uiState.$taskNoteOrigin.dropFirst()) { _ in routeStateRevision &+= 1 }
        .task(id: requestedID) {
            let requested = requestedID
            // Not this page's route, and none shown here: nothing to hand off.
            guard requested != nil || presentedTaskID != nil else { return }
            if requested != nil, onePiece?.taskID == requested {
                // One piece: the motion runs on a free main thread; the page
                // is built once it has landed, under the stand-in.
                try? await Task.sleep(nanoseconds: UInt64(TaskPageOnePiece.landing * 1_000_000_000))
            } else {
                // The click's first frame goes out before the page is built.
                await AtticGrowDriver.yieldFirstFrame(grow.style)
            }
            guard !Task.isCancelled else { return }
            let previous = noteDraft.pages.taskNotePresenter
            let previousID = displayedTaskID
            guard await noteDraft.pages.prepareTaskNoteRoute(requested) else {
                if !Task.isCancelled, uiState.taskNoteOrigin == page {
                    if page == .notes { noteDraft.pages.finishLibraryTaskRoute(requested, accepted: false) }
                    uiState.openTaskNoteID = previousID
                }
                return
            }
            guard !Task.isCancelled else { return }
            if page == .notes { noteDraft.pages.finishLibraryTaskRoute(requested, accepted: true) }
            if previous != nil, previous?.lease == nil { taskRouteGeneration &+= 1 }
            // At once: the page is the next frame (no crossfade holding two
            // editors on screen, OD-1).
            presentedTaskID = requested
            if requested != nil { grow.destinationArrived() }
            if let requested, onePiece?.taskID == requested {
                // After the page's first layout: the stand-in gives way at
                // the same places, in one frame.
                DispatchQueue.main.async { handOverOnePiece() }
            }
            #if DEBUG
            AtticGrowTrace.mark("presented", style: grow.style)
            #endif
        }
    }

    /// What the origin and the page show for `grow`. Instant (Reduced's
    /// default) is today's route: the origin until the page is there.
    struct Looks: Equatable {
        var originCurrent: Bool
        var originShows: Bool
        var destinationShows: Bool
    }

    static func looks(_ grow: AtticGrowState, shown: Bool) -> Looks {
        if grow.style == .instant {
            return Looks(originCurrent: !shown, originShows: !shown, destinationShows: true)
        }
        let originShows = (grow.phase == .idle && !shown) || grow.phase == .closing
        let destination = grow.showsDestination || (grow.phase == .idle && shown)
        return Looks(originCurrent: !shown && !grow.showsDestination, originShows: originShows,
                     destinationShows: destination)
    }

    /// The page arriving after the click: the rest of its fade-in delay,
    /// then M/E (fade: F/E). Instant: at once.
    private var pageArrival: Animation? {
        guard grow.style != .instant else { return nil }
        guard grow.style == .grow else { return AtticMotionScale.reducedFade }
        let waited = CACurrentMediaTime() - growStartedAt
        return AtticMotionScale.easeOut(AtticMotionScale.standard).delay(max(0, AtticGrowState.destinationDelay - waited))
    }

    private var reducedStyle: AtticReducedMotionStyle { AtticReducedMotionStyle.current }

    /// The route asked for changed: a page opening grows from its row; one
    /// closed without Back (a refused handoff, a purge) shrinks back.
    private func growRoute(from old: UUID?, to new: UUID?) {
        if let new {
            if let run = onePiece {
                // A second click while it goes back turns it round.
                if run.taskID == new, !run.open {
                    uiState.taskNoteGrowOrigin = nil
                    turnOnePiece(open: true)
                    return
                }
                if run.taskID != new { endOnePiece() }
                else { return }
            }
            guard grow.phase == .idle || grow.phase == .closing else { return }
            let origin = uiState.taskNoteGrowOrigin
            uiState.taskNoteGrowOrigin = nil
            if old != new, startOnePiece(new, origin: origin) { return }
            growStartedAt = CACurrentMediaTime()
            grow.open(from: origin, reduceMotion: design.reduceMotion, reducedStyle: reducedStyle)
            #if DEBUG
            AtticGrowTrace.mark("open", style: grow.style)
            #endif
            AtticGrowDriver.settleWithoutShell($grow)
        } else if let run = onePiece {
            // Back from the stand-in, Escape, or a refused hand-off.
            if run.open { reverseOnePiece(run.taskID) }
        } else if grow.phase == .opening || grow.phase == .open {
            let back = old.flatMap { uiState.taskNoteGrowOrigin(for: $0, on: page) }
            grow.close(to: back, reduceMotion: design.reduceMotion, reducedStyle: reducedStyle)
            AtticGrowDriver.settleWithoutShell($grow)
        }
    }

    /// Back, Escape or the swipe began (true) or the page refused to let
    /// go (false): the shrink starts on the click and turns round on a
    /// refusal.
    private func growBack(_ taskID: UUID, leaving: Bool) {
        if onePiece?.taskID == taskID {
            // Back runs it backwards; a refusal turns it round again.
            if leaving { reverseOnePiece(taskID) } else { turnOnePiece(open: true) }
            return
        }
        if leaving {
            grow.close(to: uiState.taskNoteGrowOrigin(for: taskID, on: page),
                       reduceMotion: design.reduceMotion, reducedStyle: reducedStyle)
            #if DEBUG
            AtticGrowTrace.mark("close", style: grow.style)
            #endif
        } else {
            grow.refuseClose()
        }
        AtticGrowDriver.settleWithoutShell($grow)
    }

    // MARK: One piece

    /// Starts the one-piece opening from a Tasks row. False: not a row (or
    /// Reduce Motion), so the page opens as before.
    private func startOnePiece(_ id: UUID, origin: AtticGrowOrigin?) -> Bool {
        #if DEBUG
        if AtticGrowTrace.disabled { return false }
        #endif
        guard page == .tasks, !design.reduceMotion, presentedTaskID == nil, let origin,
              let view = onePieceProbe.view,
              let run = TaskPageOnePieceRun.make(id, origin: origin, view: view, store: taskStore, layout: layout)
        else { return false }
        grow.reset()
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            onePieceProgress = 0
            onePieceFade = 1
            onePiece = run
        }
        onePieceProbe.watchEscape { [uiState, pages = noteDraft.pages] in
            guard let run = onePiece, run.open, !run.handedOver else { return false }
            Self.closeRoute(run.taskID, uiState: uiState, controller: pages)
            return true
        }
        // The first frame shows the row as it is (its title already the
        // head's); the motion starts on the next.
        DispatchQueue.main.async { turnOnePiece(open: true) }
        return true
    }

    /// Runs the motion towards the page (true) or back into the row.
    private func turnOnePiece(open: Bool) {
        guard var run = onePiece else { return }
        run.open = open
        run.landedBack = false
        run.generation &+= 1
        let generation = run.generation
        withAnimation(TaskPageOnePiece.spring) {
            onePiece = run
            onePieceProgress = open ? 1 : 0
        } completion: {
            landedOnePiece(generation)
        }
    }

    private func landedOnePiece(_ generation: Int) {
        guard var run = onePiece, run.generation == generation else { return }
        if run.open {
            // Turned round after the page was built (a refused Back).
            if presentedTaskID == run.taskID { handOverOnePiece() }
        } else if displayedTaskID == nil {
            endOnePiece()
        } else {
            run.landedBack = true
            onePiece = run
        }
    }

    /// The built page is there and laid out: the stand-in gives way.
    private func handOverOnePiece() {
        guard var run = onePiece, run.open, !run.handedOver, presentedTaskID == run.taskID else { return }
        run.handedOver = true
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { onePiece = run }
        onePieceProbe.stopWatchingEscape()
    }

    /// Back: the stand-in takes the page's place again (the same places)
    /// and runs into the row as it is now, or fades when it is gone.
    private func reverseOnePiece(_ taskID: UUID) {
        guard var run = onePiece, run.taskID == taskID, run.open else { return }
        let view = onePieceProbe.view
        let origin = uiState.taskNoteGrowOrigin(for: taskID, on: page)
        let pose = origin.flatMap { origin in view.flatMap { TaskPageStandInPose.make(origin, in: $0) } }
        if let pose, let view {
            run.pose = pose
            run.way = TaskPageOnePieceRun.way(taskID, pose: pose, view: view, layout: layout)
        }
        if let content = TaskPageStandInContent.make(taskID, store: taskStore) { run.content = content }
        let wasHandedOver = run.handedOver
        run.handedOver = false
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { onePiece = run }
        onePieceProbe.stopWatchingEscape()
        guard pose != nil else {
            // The row is gone: the page fades and the list comes back.
            run.open = false
            run.generation &+= 1
            let generation = run.generation
            withAnimation(AtticMotionScale.easeOut(AtticMotionScale.standard)) {
                onePiece = run
                onePieceFade = 0
            } completion: {
                landedOnePiece(generation)
            }
            return
        }
        if wasHandedOver {
            DispatchQueue.main.async { turnOnePiece(open: false) }
        } else {
            turnOnePiece(open: false)
        }
    }

    private func endOnePiece() {
        onePieceProbe.stopWatchingEscape()
        guard onePiece != nil else { return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            onePiece = nil
            onePieceProgress = 0
            onePieceFade = 1
        }
    }

    /// Back's (and a late close's) end of the route. A newer route stays.
    static func closeRoute(_ taskID: UUID, uiState: PanelUIState, controller: NotesPageController? = nil) {
        guard uiState.openTaskNoteID == taskID else { return }
        // Already-closed callers keep their synchronous route dismissal.
        guard TaskNotePresenter.open(for: taskID) != nil else { uiState.openTaskNoteID = nil; return }
        guard let controller else { return }
        // Back owns the durable handoff. SwiftUI may coalesce/suppress a
        // same-frame route change after refused navigation; releasing a lease
        // cannot depend on the next observer notification being delivered.
        Task { @MainActor in
            guard uiState.openTaskNoteID == taskID, controller.taskNotePresenter?.taskID == taskID,
                  await controller.prepareTaskNoteRoute(nil),
                  uiState.openTaskNoteID == taskID else { return }
            uiState.openTaskNoteID = nil
        }
    }

    /// OD-1: Open in window **moves** the page. The panel's surface lets go
    /// first (durably), then the window takes the one editor.
    private func openInWindow(_ taskID: UUID) {
        TaskNoteWindows.shared.open(taskID: taskID, tasks: taskStore, controller: noteDraft.pages, noteStore: noteStore,
                                    design: design, uiState: uiState)
    }
}

/// What the Tasks page needs to open task pages and fill task notes.
@MainActor
struct TaskNoteEntryServices {
    let open: (_ taskID: UUID, _ backTitle: String) -> Void
    let addFiles: (_ taskID: UUID, _ staging: TaskAttachmentStaging) -> Void
    /// The tasks with a live own note, as notes change (the row glyph and
    /// the "note kept" toast). Empty where there is no note store.
    var removeFromTasks: ((UUID) -> Void)?
    var canRemoveFromTasks: ((UUID) -> Bool)?
    /// Make Checkbox on a subtask row: the page's producer, on its open
    /// page or a headless one.
    var makeCheckbox: ((UUID) -> Void)?
    var noteOwners: AnyPublisher<Set<UUID>, Never> = Just([]).eraseToAnyPublisher()
}
