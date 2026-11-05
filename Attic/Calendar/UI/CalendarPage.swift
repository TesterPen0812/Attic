import Combine
import SwiftUI

/// The Calendar page in the panel (owner's panel design, 28 Oct; Task
/// Panel v11's Calendar page): the month controls and search on the top
/// row, the month grid of keys right under it, and the agenda below. The
/// grid scrolls with the agenda; the selected day's week pins under the
/// weekday letters while the other weeks scroll away, so scrolling (or the
/// month pill) moves between the month and the week. Search folds to the
/// selected week; Today sits between the arrows, and the footer keeps "+".
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
    @State private var scrollPosition = ScrollPosition(y: 0)
    @State private var flags = ScrollFlags()
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
                GeometryReader { proxy in
                    scroller(snapshot, viewport: proxy.size.height)
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
            model.eventRows.didWrite = { [weak library = model.store.commandLibrary, weak toasts = toasts] message in
                guard let library else { return }
                toasts?.show(message, performingAsync: { await library.replay(in: .calendar, redo: false) })
            }
        }
        .onChange(of: isReallyVisible) { _, current in
            model.setVisible(current)
            if current { model.pageAppeared() }
        }
        .onDisappear { model.setVisible(false) }
        // Another day: the agenda's task selection lets go.
        .onChange(of: snapshot.selected) { _, _ in model.taskRows.clearSelection() }
        .onChange(of: snapshot.weeks.count) { _, count in
            // The week view stays the week view when the month changes
            // (a month of another length has another offset).
            if flags.weekView { scrollPosition.scrollTo(y: CalendarMonthMath.weekViewOffset(weekCount: count)) }
        }
        // A container, so its id does not replace its controls' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("calendar-page")
    }

    // MARK: Scrolling grid and agenda

    private func scroller(_ snapshot: CalendarPageSnapshot, viewport: CGFloat) -> some View {
        let weeks = snapshot.weeks
        let pinnedIndex = snapshot.pinnedWeekIndex.flatMap { weeks.indices.contains($0) ? $0 : nil }
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
                return ScrollFlags(pinned: CalendarMonthMath.isPinned(offset: offset, pinnedIndex: pinnedIndex, was: flags.pinned),
                                   weekView: CalendarMonthMath.isWeekView(offset: offset, weekCount: weeks.count, was: flags.weekView))
            } action: { _, new in
                if flags != new { flags = new }
            }
            // The grid is cut at the weekday letters: nothing scrolls up under them.
            .clipped()
            .accessibilityIdentifier("calendar-scroll")
        }
    }

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
                        .foregroundStyle(TasksPanelDesign.toneInk(.meta, tokens: design.tokens).color)
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
                    .foregroundStyle(TasksPanelDesign.toneInk(.meta, tokens: design.tokens).color)
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
        PanelTopRow(page: .calendar, layout: layout, searchOpen: searchOpen) {
            CalendarMonthTitle(month: snapshot.month, isWeekView: flags.weekView,
                               onToggleWeekView: { toggleWeekView(weekCount: snapshot.weeks.count) })
        } pageSwitch: {
            CalendarMonthArrows(isWeekView: flags.weekView,
                                onPrevious: { afterClosingEvent { model.shift(by: -1, weekView: flags.weekView) } },
                                onNext: { afterClosingEvent { model.shift(by: 1, weekView: flags.weekView) } },
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
                scrollPosition.scrollTo(y: open ? CalendarMonthMath.weekViewOffset(weekCount: model.snapshot.weeks.count) : 0)
            }
        }
        .onChange(of: searchFocused) { _, focused in
            // Leaving an empty search puts it away.
            if !focused, model.searchText.trimmingCharacters(in: .whitespaces).isEmpty { searchOpen = false }
        }
    }

    private func afterClosingEvent(_ action: @escaping @MainActor () -> Void) {
        Task { if await model.eventRows.close() { action() } }
    }

    private func beginSearch() {
        afterClosingEvent {
            searchOpen = true
            searchFocused = true
        }
    }

    private func endSearch() {
        model.setQuery("")
        searchFocused = false
        searchOpen = false
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
