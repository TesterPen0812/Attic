import Combine
import SwiftUI

/// The Calendar page in the panel (owner's panel design, 28 Oct; Task
/// Panel v11's Calendar page): the month controls and search on the top
/// row, the month grid of keys right under it, and the agenda below. The
/// grid scrolls with the agenda; the selected day's week pins under the
/// weekday letters while the other weeks scroll away, so scrolling (or the
/// month pill) moves between the month and the week. With Week picked the
/// grid is only the selected week, so no scroll unfolds it (Accepted
/// 2026-11-10). Search folds to the selected week; Today sits between the
/// arrows, and the footer keeps "+".
struct CalendarPage: View {
    @ObservedObject var model: CalendarPageModel
    let layout: PanelPageLayout
    let taskActions: CalendarTaskRowActions
    /// The footer's "+": the add-a-task flow, for the selected day.
    let onNewTask: (DueDay) -> Void
    /// The native panel is actually ordered front. Prewarming a selected
    /// page must not request Calendar access or start visible-page work.
    var panelIsVisible = true

    @Environment(\.atticDesign) private var design
    @Environment(\.panelSharedChrome) private var sharedChrome
    @Environment(\.atticPanelPageIsCurrent) private var isCurrent
    private var isReallyVisible: Bool { isCurrent && panelIsVisible }
    @Environment(\.atticPanelToasts) private var toasts
    @Environment(\.panelComposer) private var composer
    @Environment(\.panelResumeDefaults) private var resumeDefaults
    @State private var scrollPosition = ScrollPosition(y: 0)
    @State private var flags: ScrollFlags
    /// The grid is only the selected week: Week is picked and the fold to
    /// it has finished. It trails `model.isWeekPicked` while the fold runs.
    @State private var weekOnly: Bool
    /// The scroller's last offset, read without publishing view state, so
    /// swapping the month for the week keeps everything where it was.
    @State private var lastOffset = OffsetBox()
    @State private var searchOpen = false
    @State private var searchFocused = false
    /// The keyboard's task row in the agenda (Return renames, ⇧⌘I opens).
    @FocusState private var taskFocus: AtticRowFocusID?

    /// What the scroll position decides: whether the selected week is pinned
    /// and whether the page shows only the week. Written only when one of
    /// them changes, never per scroll frame.
    struct ScrollFlags: Equatable {
        var pinned = false
        var weekView = false
    }

    final class OffsetBox { var y: CGFloat = 0 }

    init(model: CalendarPageModel, layout: PanelPageLayout, taskActions: CalendarTaskRowActions,
         onNewTask: @escaping (DueDay) -> Void, panelIsVisible: Bool = true) {
        self.model = model
        self.layout = layout
        self.taskActions = taskActions
        self.onNewTask = onNewTask
        self.panelIsVisible = panelIsVisible
        _flags = State(initialValue: ScrollFlags(weekView: model.isWeekPicked))
        _weekOnly = State(initialValue: model.isWeekPicked)
    }

    #if DEBUG
    /// Test seam: how many times the page's body has run.
    static var bodyEvaluations = 0
    #endif

    var body: some View {
        #if DEBUG
        let _ = Self.bodyEvaluations += 1
        #endif
        let snapshot = model.snapshot
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Color.clear.frame(height: layout.headerBottom)
                CalendarWeekdayRow()
                if showsDay {
                    CalendarDayView(model: model, snapshot: snapshot, eventRows: model.eventRows, taskRows: model.taskRows,
                                    taskActions: taskActions, focus: $taskFocus, focused: taskFocus,
                                    isLive: isReallyVisible, isLoadingEvents: model.isLoadingEvents,
                                    onSelectDay: { day in afterClosingEvent { model.select(day) } })
                } else {
                    GeometryReader { proxy in
                        scroller(snapshot, viewport: proxy.size.height)
                    }
                }
            }
            topRow(snapshot)
            footer(snapshot)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .background(CalendarPageInput(enabled: { isCurrent && !(composer?.isOpen() ?? false) }, today: { afterClosingEvent(model.goToToday) }, escape: {
            if model.eventRows.expandedChoice != nil { model.eventRows.expandedChoice = nil; return true }
            if model.eventRows.rowID != nil { Task { await model.eventRows.close() }; return true }
            if searchOpen { endSearch(); return true }
            return false
        }, emptyPress: {
            if searchOpen { endSearch() }
            Task { await model.eventRows.close() }
        }))
        .atticDesignCorners()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            model.setVisible(isReallyVisible)
            // A retained, prewarmed Calendar is mounted but not the shown page.
            if isReallyVisible { model.pageAppeared() }
            #if DEBUG
            if isReallyVisible, ProcessInfo.processInfo.environment["ATTIC_UI_TEST_SCREEN9_DAY"] == "1" {
                model.setDayView(true)
            }
            #endif
            model.eventRows.didWrite = { [weak library = model.store.commandLibrary, weak toasts = toasts] message in
                guard let library else { return }
                toasts?.show(message, performingAsync: { await library.replay(in: .calendar, redo: false) })
            }
        }
        .onChange(of: isReallyVisible) { _, current in
            model.setVisible(current)
            if current { model.pageAppeared() }
            #if DEBUG
            if current, ProcessInfo.processInfo.environment["ATTIC_UI_TEST_SCREEN9_DAY"] == "1" {
                model.setDayView(true)
            }
            #endif
        }
        .onDisappear { model.setVisible(false) }
        // Another day: the agenda's task selection lets go.
        .onChange(of: snapshot.selected) { _, _ in model.taskRows.clearSelection() }
        // The agent picks a day while you watch (the spark taps its key).
        .onReceive(AgentWatchBoard.shared.$dayRequest.compactMap { $0 }) { request in
            AgentWatchBoard.shared.consumeDay(request.id)
            model.select(request.day)
        }
        .onChange(of: snapshot.weeks.count) { _, count in
            // The week view stays the week view when the month changes
            // (a month of another length has another offset).
            if flags.weekView, !weekOnly { scrollPosition.scrollTo(y: CalendarMonthMath.weekViewOffset(weekCount: count)) }
        }
        .onChange(of: model.isWeekPicked) { _, week in foldToPickedView(week: week) }
        // A container, so its id does not replace its controls' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar-page")
    }

    // MARK: Scrolling grid and agenda

    private func scroller(_ snapshot: CalendarPageSnapshot, viewport: CGFloat) -> some View {
        let (weeks, pinnedIndex) = gridWeeks(snapshot)
        let rowTop = pinnedIndex.map { CGFloat($0) * CalendarDesign.weekPitch }
        return PanelComposerClearance { extra in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    // Flat days (Accepted 2026-10-30): no glass in the grid.
                    VStack(spacing: 0) {
                        ForEach(weeks) { week in
                            CalendarWeekRow(week: week, isWeekView: flags.weekView, onSelect: { day in afterClosingEvent { model.select(day) } })
                                .equatable()
                                // The selected week is drawn once, by its held row.
                                .accessibilityHidden(week.containsSelection)
                        }
                    }
                    agenda(snapshot)
                        .frame(minHeight: viewport, alignment: .top)
                }
                .padding(.bottom, CalendarDesign.agendaBottom)
                .background(PanelComposerScrollKeeper().frame(width: 0, height: 0))
                .background(PanelResumeScrollKeeper(key: "calendar", ready: !model.isLoadingEvents, navigationID: snapshot.selected.description + snapshot.query).frame(width: 0, height: 0))
                // What scrolls under the selected week is hidden behind it and
                // fades in below it once it is held (item 14, owner 2026-10-31).
                // Both the cut and the held row follow the scroll in the same
                // frame, so each frame draws the week once.
                .mask(alignment: .top) { CalendarScrollMask(rowTop: rowTop, pinned: flags.pinned) }
                .overlay(alignment: .top) {
                    if let pinnedIndex, let rowTop {
                        CalendarWeekRow(week: weeks[pinnedIndex], isWeekView: flags.weekView, onSelect: { day in afterClosingEvent { model.select(day) } })
                            .equatable()
                            .visualEffect { content, proxy in
                                content.offset(y: CalendarMonthMath.heldRowTop(
                                    rowTop: rowTop, contentTop: proxy.frame(in: .scrollView).minY))
                            }
                    }
                }
            }
            .contentMargins(.bottom, extra, for: .scrollContent)
            .scrollIndicators(.never)
            // Clean cut (3 Oct): the native soft scroll edge stays off.
            .atticScrollEdgeEffect()
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: ScrollFlags.self) { geometry in
                let offset = geometry.contentOffset.y + geometry.contentInsets.top
                lastOffset.y = offset
                return ScrollFlags(pinned: CalendarMonthMath.isPinned(offset: offset, pinnedIndex: pinnedIndex, was: flags.pinned),
                                   weekView: weekOnly
                                       || CalendarMonthMath.isWeekView(offset: offset, weekCount: weeks.count, was: flags.weekView))
            } action: { _, new in
                if flags != new { flags = new }
            }
            // The grid is cut at the weekday letters: nothing scrolls up under them.
            .clipped()
            .accessibilityIdentifier("calendar-scroll")
        }
    }

    /// The grid's rows and the selected one's index: the whole month, or
    /// with Week picked only the selected week.
    private func gridWeeks(_ snapshot: CalendarPageSnapshot) -> (weeks: [CalendarGridWeek], pinned: Int?) {
        let pinned = snapshot.pinnedWeekIndex.flatMap { snapshot.weeks.indices.contains($0) ? $0 : nil }
        if weekOnly, let pinned { return ([snapshot.weeks[pinned]], 0) }
        return (snapshot.weeks, pinned)
    }

    /// The grid's row count as drawn: 1 with only the week.
    private var gridWeekCount: Int { gridWeeks(model.snapshot).weeks.count }

    @ViewBuilder
    private func agenda(_ snapshot: CalendarPageSnapshot) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            // Every day on its own, each with its grey date tile, empty days
            // too (owner, 2026-10-31: the older agenda).
            ForEach(Array(snapshot.groups.enumerated()), id: \.element.id) { index, group in
                if snapshot.isSearching && (index == 0 ? group.day.year != snapshot.today.year
                    : snapshot.groups[index - 1].day.year != group.day.year) {
                    Text(verbatim: String(group.day.year))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AtticSurfaceInk.toneInk(.meta, tokens: design.tokens).color)
                        .padding(.horizontal, CalendarDesign.dayPadding)
                        .padding(.top, 4)
                        .padding(.bottom, 6)
                        .accessibilityLabel(String(group.day.year))
                        .accessibilityIdentifier("calendar-search-year-\(group.day.year)")
                }
                CalendarAgendaDay(group: group, today: snapshot.today, taskActions: taskActions,
                                  rows: model.taskRows, eventRows: model.eventRows, focus: $taskFocus, focused: taskFocus,
                                  onSelectDay: { day in afterClosingEvent { model.select(day) } })
            }
            if snapshot.showsNoMatches {
                Text("No matches")
                    .font(.system(size: CalendarDesign.noMatchesFont))
                    .foregroundStyle(AtticSurfaceInk.toneInk(.meta, tokens: design.tokens).color)
                    .padding(.vertical, CalendarDesign.noMatchesPaddingY)
                    .padding(.horizontal, CalendarDesign.noMatchesPaddingX)
                    .accessibilityIdentifier("calendar-no-matches")
            }
        }
        .padding(.top, CalendarDesign.agendaTop)
        .padding(.horizontal, CalendarDesign.agendaInset)
    }

    // MARK: Top row

    /// The top row (Accepted 2026-10-30): "October 2026" after the pin,
    /// then ‹ › in one capsule, ••• and Search. Opening Search folds the
    /// rest away and the field fills the row.
    private func topRow(_ snapshot: CalendarPageSnapshot) -> some View {
        PanelTopRow(page: .calendar, layout: layout, searchOpen: searchOpen, moreCommands: { moreCommands() }) {
            CalendarMonthTitle(month: snapshot.month, isWeekView: flags.weekView, dayView: showsDay ? snapshot.selected : nil,
                               onToggleWeekView: {
                                   // From Day, back to the picked view; in Week, to the month.
                                   if showsDay { afterClosingEvent { setView(model.isWeekPicked ? .week : .month) } }
                                   else if model.isWeekPicked { model.pickWeek(false) }
                                   else { toggleWeekView(weekCount: snapshot.weeks.count) }
                               })
        } pageSwitch: {
            CalendarMonthArrows(isWeekView: flags.weekView, isDayView: showsDay,
                                onPrevious: { afterClosingEvent { step(-1) } },
                                onNext: { afterClosingEvent { step(1) } },
                                todayShown: CalendarTodayButton.isShown(selected: snapshot.selected, today: snapshot.today),
                                onToday: { afterClosingEvent(model.goToToday) })
        } search: {
            if searchOpen {
                AtticTabsSearchField(placeholder: String(localized: "Search"),
                                     text: Binding(get: { model.searchText }, set: { model.setQuery($0) }),
                                     isFocused: $searchFocused, floating: true, onEscape: endSearch, header: true)
                    .atticDesignCorners()
                    .accessibilityIdentifier("calendar-search")
                    .transition(PanelTopRowLayout.fieldTransition)
            } else {
                PanelTopRowSearchButton(label: "Search", identifier: "calendar-search-button", action: beginSearch)
                    .transition(.opacity)
            }
        }
        .animation(CalendarDesign.searchAnimation(opening: searchOpen, reduceMotion: design.reduceMotion), value: searchOpen)
        .onChange(of: searchOpen) { _, open in
            withAnimation(AtticMotionPreset.expand.animation(reduceMotion: design.reduceMotion)) {
                scrollPosition.scrollTo(y: open ? CalendarMonthMath.weekViewOffset(weekCount: gridWeekCount) : 0)
            }
        }
        .onChange(of: searchFocused) { _, focused in
            // Leaving an empty search puts it away.
            if !focused, model.searchText.trimmingCharacters(in: .whitespaces).isEmpty { searchOpen = false }
        }
    }

    /// The Day view, unless a search has the page.
    private var showsDay: Bool { model.isDayView && !searchOpen && !model.snapshot.isSearching }

    /// What ••• ticks: as before, Week while the grid shows the week.
    private var currentView: CalendarViewMode { showsDay ? .day : flags.weekView ? .week : .month }

    /// ‹ ›: a day in the Day view, otherwise a week or a month.
    private func step(_ n: Int) {
        if showsDay { model.shiftDay(by: n) }
        else { model.shift(by: n, weekView: flags.weekView) }
    }

    /// ••• (Accepted 2026-11-05, "Page-specific options"; Day, 2026-11-09):
    /// the views the page has, as read when it opens, and going to today.
    private func moreCommands() -> [AtticMenuCommand] {
        let snapshot = model.snapshot
        return Self.moreCommands(view: currentView, isOnToday: snapshot.selected == snapshot.today,
                                 setView: { view in
                                     // Leaving or entering Day replaces what an open event sits in.
                                     if view == .day || model.isDayView { afterClosingEvent { setView(view) } }
                                     else { setView(view) }
                                 },
                                 goToToday: { afterClosingEvent(model.goToToday) })
    }

    static func moreCommands(view: CalendarViewMode, isOnToday: Bool, setView: @escaping (CalendarViewMode) -> Void,
                             goToToday: @escaping () -> Void) -> [AtticMenuCommand] {
        var commands = [AtticMenuCommand.header(String(localized: "View"))]
        let views: [(mode: CalendarViewMode, title: String)] = [
            (.month, String(localized: "Month")), (.week, String(localized: "Week")), (.day, String(localized: "Day"))
        ]
        for (mode, title) in views {
            commands.append(AtticMenuCommand(verbatim: title, state: view == mode ? .on : .off) { setView(mode) })
        }
        commands.append(AtticMenuCommand(verbatim: String(localized: "Go to Today"), shortcut: KeyboardShortcut("t", modifiers: .command),
                                         isDisabled: isOnToday, startsSection: true, action: goToToday))
        return commands
    }

    private func setView(_ view: CalendarViewMode) {
        if view == .day {
            model.setDayView(true)
            return
        }
        let week = view == .week
        guard model.isDayView else {
            if week != model.isWeekPicked { model.pickWeek(week) }
            // Month on a Month folded by scrolling: back to the month, as before.
            else if !week, flags.weekView { toggleWeekView(weekCount: model.snapshot.weeks.count) }
            return
        }
        // The grid comes back already at the month or the week.
        let target = week ? CalendarMonthMath.weekViewOffset(weekCount: 1) : 0
        PanelResumeScrollKeeper.remember(target, key: "calendar", in: resumeDefaults)
        weekOnly = week
        flags = ScrollFlags(pinned: week, weekView: week)
        scrollPosition.scrollTo(y: target)
        model.pickWeek(week)
        model.setDayView(false)
    }

    private func afterClosingEvent(_ action: @escaping @MainActor () -> Void) {
        Task { if await model.eventRows.close() { action() } }
    }

    private func beginSearch() {
        afterClosingEvent {
            // From Day, the agenda comes back folded to the week.
            if model.isDayView {
                PanelResumeScrollKeeper.remember(CalendarMonthMath.weekViewOffset(weekCount: gridWeekCount),
                                                 key: "calendar", in: resumeDefaults)
            }
            searchOpen = true
            searchFocused = true
        }
    }

    private func endSearch() {
        model.setQuery("")
        searchFocused = false
        searchOpen = false
    }

    /// Week picked: the month folds to the week as it does on a scroll, and
    /// then the weeks above and below go, at an offset that draws the same
    /// frame. Month picked: the weeks come back at that same frame, and the
    /// grid unfolds to the month. Neither changes the fold's motion.
    private func foldToPickedView(week: Bool) {
        guard weekOnly != week else { return }
        let count = model.snapshot.weeks.count
        // Every row but the selected week's: what the swap adds or removes
        // above the agenda, so the agenda stays put across it.
        let above = CGFloat(max(0, count - 1)) * CalendarDesign.weekPitch
        let folded = CalendarMonthMath.weekViewOffset(weekCount: count)
        guard isReallyVisible, !showsDay else {
            weekOnly = week
            flags = ScrollFlags(pinned: week, weekView: week)
            scrollPosition.scrollTo(y: week ? CalendarMonthMath.weekViewOffset(weekCount: 1) : 0)
            return
        }
        if week {
            // The agenda keeps its place: at least folded, less the rows that go.
            let toWeek = {
                guard model.isWeekPicked, !weekOnly else { return }
                weekOnly = true
                flags.weekView = true
                scrollPosition.scrollTo(y: max(lastOffset.y, folded) - above)
            }
            if lastOffset.y >= folded - 2 || design.reduceMotion {
                toWeek()
                return
            }
            // The fold's own motion first. A scroll animation reports no
            // completion of its own, so the swap waits until the scroll has
            // come to rest at the fold (a few still frames, 2 s at most).
            withAnimation(AtticMotionPreset.expand.animation(reduceMotion: design.reduceMotion)) {
                scrollPosition.scrollTo(y: folded)
            }
            Task { @MainActor in
                var still = 0
                for _ in 0..<120 where still < 3 {
                    try? await Task.sleep(nanoseconds: 16_000_000)
                    guard model.isWeekPicked, !weekOnly else { return }
                    still = abs(lastOffset.y - folded) < 0.25 ? still + 1 : 0
                }
                toWeek()
            }
        } else {
            weekOnly = false
            scrollPosition.scrollTo(y: lastOffset.y + above)
            Task { @MainActor in
                guard !model.isWeekPicked, !weekOnly else { return }
                withAnimation(AtticMotionPreset.expand.animation(reduceMotion: design.reduceMotion)) {
                    scrollPosition.scrollTo(y: 0)
                }
            }
        }
    }

    private func toggleWeekView(weekCount: Int) {
        let target = flags.weekView ? 0 : CalendarMonthMath.weekViewOffset(weekCount: weekCount)
        withAnimation(AtticMotionPreset.expand.animation(reduceMotion: design.reduceMotion)) {
            scrollPosition.scrollTo(y: target)
        }
    }

    // MARK: Footer

    /// Adaptive picks C3 (Accepted 2026-11-01): Today has moved to the
    /// header. The shared footer keeps the existing add route.
    @ViewBuilder
    private func footer(_ snapshot: CalendarPageSnapshot) -> some View {
        ZStack {
            if sharedChrome == nil {
                ownFooter(snapshot)
            } else {
                // A view for the lending to hang on (an empty group has none).
                Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        .panelBottomBar(.calendar,
                        look: PanelBottomBarLook(middle: .none, plus: PanelBottomBarLook.calendarPlus),
                        actions: PanelBottomBarActions(plus: { [model] in onNewTask(model.newTaskDay) }))
    }

    private func ownFooter(_ snapshot: CalendarPageSnapshot) -> some View {
        let flat = design.effectiveControls != .liquidGlass
        let height = CalendarDesign.footerHeight
        return AtticControlGroup {
            HStack(spacing: TasksDesignMetrics.footerGap) {
                // The page switch is the Tall island (Accepted 2026-10-31).
                Spacer(minLength: 0)
                AtticRaisedButton(systemName: "plus", label: "New event", size: CGSize(width: height, height: height),
                                  emphasisedGlyph: true, flat: flat, cornerRadius: TasksDesignMetrics.footerRadius) {
                    onNewTask(model.newTaskDay)
                }
                .accessibilityIdentifier("calendar-new-task")
            }
        }
        .atticDesignCorners()
        .padding(.horizontal, layout.chromeInsets.leading)
        .padding(.bottom, layout.chromeInsets.bottom)
    }
}

/// The views ••• offers. Month and Week are the two states of the grid (the
/// title folds one into the other); Day replaces the grid with the hours.
enum CalendarViewMode: Equatable {
    case month, week, day
}

/// The agenda's mask, in the scrolled content: what lies under the selected
/// week's held row is cut, and below it the agenda fades in over
/// `CalendarDesign.agendaFade` once the week is held (Accepted 2026-10-30,
/// "Scrolling"). The cut follows the held row in the same frame as the
/// scroll (`CalendarMonthMath.heldRowTop`); before the week is held it is
/// the week's own row, which the held row covers exactly. The body re-runs
/// only when the week pins or unpins; the fade comes and goes in the hover
/// motion (the design's quick fade).
struct CalendarScrollMask: View {
    /// The selected week's row top in the content; nil when none is shown.
    let rowTop: CGFloat?
    let pinned: Bool

    @Environment(\.atticDesign) private var design

    #if DEBUG
    /// Test seam: the `pinned` of each body run, so a hosted test can see
    /// that the mounted scroller carries this mask and follows the pin.
    static var renders: [Bool] = [] {
        didSet { if renders.count > AtticDiagnosticHistory.capacity { renders.removeFirst(renders.count - AtticDiagnosticHistory.retainedAfterOverflow) } }
    }
    #endif

    var body: some View {
        #if DEBUG
        let _ = Self.renders.append(pinned)
        #endif
        ZStack(alignment: .top) {
            Color.black
            if let rowTop {
                VStack(spacing: 0) {
                    Color.black.frame(height: CalendarDesign.weekPitch)
                    LinearGradient(colors: [.black.opacity(pinned ? 1 : 0), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: CalendarDesign.agendaFade)
                        .animation(AtticMotionPreset.hover.animation(reduceMotion: design.reduceMotion), value: pinned)
                }
                .visualEffect { content, proxy in
                    content.offset(y: CalendarMonthMath.heldRowTop(
                        rowTop: rowTop, contentTop: proxy.frame(in: .scrollView).minY))
                }
                .blendMode(.destinationOut)
            }
        }
        .compositingGroup()
    }
}

/// Today in the bottom bar (Accepted 2026-10-30): shown only while another
/// day is selected, fading in and out. It keeps its place while hidden. A
/// glass group ignores a plain opacity on its members, so it fades out of
/// its glass (`atticControlAway`) and then drops the glass (`atticControlGone`).
struct CalendarTodayButton: View {
    let isShown: Bool
    let flat: Bool
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var away: Bool
    @State private var gone: Bool

    init(isShown: Bool, flat: Bool, action: @escaping () -> Void) {
        self.isShown = isShown
        self.flat = flat
        self.action = action
        _away = State(initialValue: !isShown)
        _gone = State(initialValue: !isShown)
    }

    static func isShown(selected: DueDay, today: DueDay) -> Bool { selected != today }

    var body: some View {
        let tokens = design.tokens
        Button(action: action) {
            Text("Today")
                .font(.system(size: CalendarDesign.todayFont, weight: .medium))
                .foregroundStyle(tokens.ink(.heading).color)
                .padding(.horizontal, CalendarDesign.todayPaddingX)
                .frame(height: CalendarDesign.footerHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(AtticRaisedButtonStyle(cornerRadius: TasksDesignMetrics.footerRadius, flat: flat))
        .focusEffectDisabled()
        .environment(\.atticControlAway, away)
        .environment(\.atticControlGone, gone)
        .opacity(away ? 0 : 1)
        .allowsHitTesting(isShown)
        .accessibilityHidden(!isShown)
        .help(String(localized: "Go to today"))
        .accessibilityIdentifier("calendar-today")
        .onChange(of: isShown) { _, shown in
            let animation = AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion, showing: shown)
            if shown {
                gone = false
                withAnimation(animation) { away = false }
            } else {
                withAnimation(animation) { away = true } completion: { if away { gone = true } }
            }
        }
    }
}
