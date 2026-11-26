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
    @State private var onePiece = TaskPageMotion()
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
        // One piece: the built page shows once the stand-in gives way to it.
        let onePieceOn = onePiece.isActive
        let pageShows = onePieceOn ? onePiece.handedOver : looks.destinationShows
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
                origin(shown != nil)
                    .modifier(PanelPageVisibility(isCurrent: onePieceOn ? !onePiece.handedOver : looks.originCurrent,
                                                  restingOffset: 0, disablesWhenHidden: false,
                                                  opacityOverride: onePieceOn ? .init(shows: !onePiece.handedOver, animation: nil)
                                                    : grow.style == .instant ? nil
                                                    : .init(shows: looks.originShows,
                                                            animation: grow.originAnimation(showing: looks.originShows))))
                    .environment(\.taskPageMotion, page == .tasks ? onePiece : nil)
            }
            if let taskID = shown {
                TaskNotePageContainer(taskID: taskID, tasks: taskStore, controller: noteDraft.pages,
                                      noteStore: noteStore, layout: layout,
                                      backTitle: uiState.taskNoteBackTitle,
                                      onOpenInWindow: { openInWindow(taskID) },
                                      onLeaving: { leaving in growBack(taskID, leaving: leaving) }) {
                    Self.closeRoute(taskID, uiState: uiState, controller: noteDraft.pages)
                }
                .onAppear { onePiece.trace("page in") }
                .onDisappear { onePiece.trace("page gone") }
                // The page's own top row is this page's (its Find takes it, N4 B).
                .environment(\.panelTopRowPage, page)
                .opacity(pageShows ? 1 : 0)
                .animation(onePieceOn ? nil : grow.destinationAnimation(showing: pageShows), value: pageShows)
                .allowsHitTesting(pageShows)
                .accessibilityHidden(!pageShows)
                .transition(.asymmetric(insertion: onePieceOn ? .identity : .opacity.animation(pageArrival), removal: .identity))
                .id("\(taskID)-\(taskRouteGeneration)")
            }
            if page == .tasks {
                // The head and first lines from the task's data, from the
                // click's first frame, until the built page takes over.
                TaskPageOnePieceLayer(motion: onePiece, layout: layout, backTitle: uiState.taskNoteBackTitle,
                                      onAppear: onePieceStandInAppeared) {
                    if let id = onePiece.taskID { Self.closeRoute(id, uiState: uiState, controller: noteDraft.pages) }
                }
                .zIndex(3)
            }
            AtticGrowLayer(state: grow, onFinish: { $grow.finish($0) })
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .zIndex(2)
        }
        .coordinateSpace(.named(TaskPageOnePiece.space))
        .background(TaskPageOnePieceProbe(box: onePieceProbe).accessibilityHidden(true))
        .onChange(of: requestedID, initial: true) { old, new in growRoute(from: old, to: new) }
        .onChange(of: shown != nil, initial: true) { _, covered in
            // One piece moves the bars itself, on its own spring.
            if !onePiece.isActive { sharedChrome?.setCovered(covered, page: page) }
        }
        .onChange(of: shown == nil) { _, gone in
            onePiece.trace("shown gone=\(gone)")
            if gone, onePiece.landedBack { endOnePiece() }
        }
        .onDisappear {
            endOnePiece()
            sharedChrome?.setCovered(false, page: page)
        }
        .onReceive(uiState.$openTaskNoteID.dropFirst()) { _ in routeStateRevision &+= 1 }
        .onReceive(uiState.$taskNoteOrigin.dropFirst()) { _ in routeStateRevision &+= 1 }
        .task(id: requestedID) {
            let requested = requestedID
            // Not this page's route, and none shown here: nothing to hand off.
            guard requested != nil || presentedTaskID != nil else { return }
            if requested != nil, onePiece.taskID == requested {
                // One piece: the motion runs on a free main thread; the page
                // is built once the spring has settled, under the stand-in.
                guard await onePiece.waitForLanding() else { return }
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
            if let requested, onePiece.taskID == requested { handOverOnePiece() }
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
            if onePiece.isActive {
                if onePiece.taskID == new {
                    // A second click while it goes back turns it round.
                    uiState.taskNoteGrowOrigin = nil
                    if !onePiece.open { turnOnePiece(open: true) }
                    return
                }
                endOnePiece()
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
        } else if onePiece.isActive {
            // Back or Escape from the stand-in, or a refused hand-off.
            if onePiece.open, let id = onePiece.taskID { reverseOnePiece(id) }
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
        if onePiece.taskID == taskID {
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
    /// Reduce Motion: instant), so the page opens as before.
    private func startOnePiece(_ id: UUID, origin: AtticGrowOrigin?) -> Bool {
        #if DEBUG
        if AtticGrowTrace.disabled { return false }
        #endif
        guard page == .tasks, !design.reduceMotion, presentedTaskID == nil, let origin,
              let view = onePieceProbe.view,
              let pose = TaskPagePose.make(origin, in: view, layout: layout),
              let content = TaskPageStandInContent.make(id, store: taskStore)
        else { return false }
        grow.reset()
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { onePiece.begin(id, content: content, pose: pose) }
        onePiece.open = true
        onePiece.landingPending = true
        // The bars give way on the click, not when the page shows.
        sharedChrome?.setCovered(true, page: page, onePiece: true)
        watchOnePieceEscape()
        // The spring starts once the stand-in is in, at the row's place
        // (`onePieceStandInAppeared`).
        return true
    }

    /// Escape goes Back while the stand-in is the page on its way to it (the
    /// click, or a turn round); the built page answers Escape itself.
    private func watchOnePieceEscape() {
        onePieceProbe.watchEscape { [uiState, pages = noteDraft.pages] in
            guard onePiece.isActive, onePiece.open, !onePiece.handedOver, let id = onePiece.taskID else { return false }
            Self.closeRoute(id, uiState: uiState, controller: pages)
            return true
        }
    }

    /// The stand-in came in (the click, or Back from the built page): the
    /// spring runs from where everything is now.
    private func onePieceStandInAppeared() {
        onePiece.trace("standInAppeared")
        guard onePiece.isActive else { return }
        if onePiece.open, onePiece.progress < 1 { turnOnePiece(open: true) }
        if !onePiece.open, onePiece.progress > 0 { turnOnePiece(open: false) }
    }

    /// Runs the motion towards the page (true) or back into the row, from
    /// wherever it is (the spring keeps its speed as it turns).
    private func turnOnePiece(open: Bool) {
        onePiece.trace("turn \(open)")
        guard onePiece.isActive else { return }
        onePiece.open = open
        onePiece.landedBack = false
        onePiece.generation &+= 1
        let generation = onePiece.generation
        if open {
            onePiece.landingPending = true
            if !onePiece.handedOver { watchOnePieceEscape() }
        } else {
            onePieceProbe.stopWatchingEscape()
            onePiece.landed(false)
        }
        let target: CGFloat = open ? 1 : 0
        #if DEBUG
        TaskPageMotion.lineDrawsForTesting = []
        #endif
        // It lands when every spring this started is over. What holds one is
        // the stand-in, Tasks' top row and the list the page opened from
        // (`TaskPageListFollows`). On Back that list is drawn again when the
        // route has closed, and its spring runs from then.
        withAnimation(TaskPageOnePiece.spring, completionCriteria: .removed) {
            onePiece.progress = target
        } completion: {
            landedOnePiece(generation)
        }
        // The shell's bars follow on a spring of their own: nothing of the
        // shell's can hold the landing.
        withAnimation(TaskPageOnePiece.spring) { sharedChrome?.setGivingWay(target, page: page) }
    }

    private func landedOnePiece(_ generation: Int) {
        onePiece.trace("landed gen \(generation) presented=\(presentedTaskID != nil) displayed=\(displayedTaskID != nil)")
        guard onePiece.isActive, onePiece.generation == generation else { return }
        if onePiece.open {
            onePiece.landed(true)
            // Turned round after the page was built (a refused Back).
            if presentedTaskID == onePiece.taskID { handOverOnePiece() }
        } else if displayedTaskID == nil {
            endOnePiece()
        } else {
            onePiece.landedBack = true
        }
    }

    /// The built page is there and laid out: the stand-in gives way to it in
    /// one frame. The page's editor mounts a turn after the route shows it
    /// (its presenter is made on appear), so this waits for the mount, then
    /// one turn more for its first layout.
    private func handOverOnePiece(waits: Int = 0) {
        guard onePiece.isActive, onePiece.open, !onePiece.handedOver, !onePiece.landingPending,
              let id = onePiece.taskID, presentedTaskID == id else { return }
        if waits < 12, TaskNotePresenter.open(for: id)?.isMounted != true {
            DispatchQueue.main.async { handOverOnePiece(waits: waits + 1) }
            return
        }
        if waits < 100 {
            DispatchQueue.main.async { handOverOnePiece(waits: 100) }
            return
        }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { onePiece.handedOver = true }
        onePiece.trace("handedOver waits=\(waits)")
        onePieceProbe.stopWatchingEscape()
    }

    /// Back: the stand-in takes the page's place again (the same places) and
    /// runs into the row as it is now, or fades when the row is gone.
    private func reverseOnePiece(_ taskID: UUID) {
        onePiece.trace("reverse")
        guard onePiece.taskID == taskID, onePiece.open else { return }
        onePieceProbe.stopWatchingEscape()
        let origin = uiState.taskNoteGrowOrigin(for: taskID, on: page)
        let pose = origin.flatMap { origin in onePieceProbe.view.flatMap { TaskPagePose.make(origin, in: $0, layout: layout) } }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            onePiece.retarget(content: TaskPageStandInContent.make(taskID, store: taskStore), pose: pose)
            onePiece.rowGone = pose == nil
        }
        // The bars come back on the way down.
        sharedChrome?.setCovered(false, page: page, onePiece: true)
        // The parked stand-in shows again at the page's places, drawn there,
        // and runs back from them.
        if onePiece.handedOver { withTransaction(still) { onePiece.handedOver = false } }
        turnOnePiece(open: false)
    }

    private func endOnePiece() {
        onePiece.trace("end")
        onePieceProbe.stopWatchingEscape()
        guard onePiece.isActive else { return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            onePiece.end()
            sharedChrome?.endOnePiece(page: page)
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
