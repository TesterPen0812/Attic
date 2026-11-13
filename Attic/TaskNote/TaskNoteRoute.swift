import Combine
import SwiftUI

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

    /// The route this page serves: only a page opened from here.
    private var requestedID: UUID? { uiState.taskNoteOrigin == page ? uiState.openTaskNoteID : nil }

    // A remounted section still shows its retained owner during a handoff.
    private var displayedTaskID: UUID? {
        presentedTaskID ?? (uiState.taskNoteOrigin == page ? noteDraft.pages.taskNotePresenter?.taskID : nil)
    }

    var body: some View {
        let _ = routeStateRevision
        let shown = isReady ? displayedTaskID : nil
        let looks = Self.looks(grow, shown: shown != nil)
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
                    .modifier(PanelPageVisibility(isCurrent: looks.originCurrent, restingOffset: 0, disablesWhenHidden: false,
                                                  opacityOverride: grow.style == .instant ? nil
                                                    : .init(shows: looks.originShows,
                                                            animation: grow.originAnimation(showing: looks.originShows))))
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
                .opacity(looks.destinationShows ? 1 : 0)
                .animation(grow.destinationAnimation(showing: looks.destinationShows), value: looks.destinationShows)
                .allowsHitTesting(looks.destinationShows)
                .accessibilityHidden(!looks.destinationShows)
                .transition(.asymmetric(insertion: .opacity.animation(pageArrival), removal: .identity))
                .id("\(taskID)-\(taskRouteGeneration)")
            }
            AtticGrowLayer(state: grow, onFinish: { $grow.finish($0) })
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .zIndex(2)
        }
        .onChange(of: requestedID, initial: true) { old, new in growRoute(from: old, to: new) }
        .onChange(of: shown != nil, initial: true) { _, covered in sharedChrome?.setCovered(covered, page: page) }
        .onDisappear { sharedChrome?.setCovered(false, page: page) }
        .onReceive(uiState.$openTaskNoteID.dropFirst()) { _ in routeStateRevision &+= 1 }
        .onReceive(uiState.$taskNoteOrigin.dropFirst()) { _ in routeStateRevision &+= 1 }
        .task(id: requestedID) {
            let requested = requestedID
            // Not this page's route, and none shown here: nothing to hand off.
            guard requested != nil || presentedTaskID != nil else { return }
            // The click's first frame goes out before the page is built.
            await AtticGrowDriver.yieldFirstFrame(grow.style)
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
        if new != nil {
            guard grow.phase == .idle || grow.phase == .closing else { return }
            let origin = uiState.taskNoteGrowOrigin
            uiState.taskNoteGrowOrigin = nil
            growStartedAt = CACurrentMediaTime()
            grow.open(from: origin, reduceMotion: design.reduceMotion, reducedStyle: reducedStyle)
            #if DEBUG
            AtticGrowTrace.mark("open", style: grow.style)
            #endif
            AtticGrowDriver.settleWithoutShell($grow)
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
