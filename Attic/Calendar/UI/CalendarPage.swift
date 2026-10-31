import SwiftUI

/// The Calendar page in the panel (owner's panel design, 28 Oct; Task
/// Panel v11's Calendar page): the month controls and search on the top
/// row, the month grid of keys right under it, and the agenda below. The
/// grid scrolls with the agenda; the selected day's week pins under the
/// weekday letters while the other weeks scroll away, so scrolling (or the
/// month pill) moves between the month and the week. The footer has Today
/// and "+".
struct CalendarPage: View {
    @ObservedObject var model: CalendarPageModel
    let layout: PanelPageLayout
    let taskActions: CalendarTaskRowActions
    /// The footer's "+": the add-a-task flow, for the selected day.
    let onNewTask: (DueDay) -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.panelSharedChrome) private var sharedChrome
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
        .atticDesignCorners()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.pageAppeared() }
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
        let pinnedIndex = snapshot.pinnedWeekIndex
        return ScrollView(.vertical) {
            VStack(spacing: 0) {
                // Flat days (Accepted 2026-10-30): no glass in the grid.
                VStack(spacing: 0) {
                    ForEach(weeks) { week in
                        CalendarWeekRow(week: week, isWeekView: flags.weekView, onSelect: model.select)
                            .equatable()
                    }
                }
                agenda(snapshot)
                    .frame(minHeight: viewport, alignment: .top)
            }
            .padding(.bottom, CalendarDesign.agendaBottom)
        }
        .scrollIndicators(.never)
        // Clean cut (3 Oct): the native soft scroll edge stays off.
        .atticScrollEdgeEffect()
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: ScrollFlags.self) { geometry in
            let offset = geometry.contentOffset.y + geometry.contentInsets.top
            return ScrollFlags(pinned: CalendarMonthMath.isPinned(offset: offset, pinnedIndex: pinnedIndex),
                               weekView: CalendarMonthMath.isWeekView(offset: offset, weekCount: weeks.count))
        } action: { _, new in
            if flags != new { flags = new }
        }
        // While the selected week is pinned, what scrolls under it is hidden
        // behind it and fades in below it (a static gradient), and its copy
        // stays put above.
        .mask(alignment: .top) { CalendarScrollMask(pinned: flags.pinned) }
        .overlay(alignment: .top) {
            if flags.pinned, let pinnedIndex, weeks.indices.contains(pinnedIndex) {
                CalendarWeekRow(week: weeks[pinnedIndex], isWeekView: flags.weekView, onSelect: model.select)
                    .equatable()
            }
        }
        .accessibilityIdentifier("calendar-scroll")
    }

    @ViewBuilder
    private func agenda(_ snapshot: CalendarPageSnapshot) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(snapshot.entries) { entry in
                switch entry {
                case let .day(group):
                    CalendarAgendaDay(group: group, today: snapshot.today, taskActions: taskActions,
                                      rows: model.taskRows, focus: $taskFocus, focused: taskFocus,
                                      onSelectDay: model.select)
                case let .free(run):
                    CalendarFreeDaysLine(run: run, onSelectDay: model.select)
                }
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
                                onPrevious: { model.shift(by: -1, weekView: flags.weekView) },
                                onNext: { model.shift(by: 1, weekView: flags.weekView) })
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
        .onChange(of: searchFocused) { _, focused in
            // Leaving an empty search puts it away.
            if !focused, model.searchText.trimmingCharacters(in: .whitespaces).isEmpty { searchOpen = false }
        }
    }

    private func beginSearch() {
        searchOpen = true
        searchFocused = true
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

    /// The bottom bar (Accepted 2026-10-29/30): the page switch, Today,
    /// then "+". In the panel the shell draws it once for every page
    /// (owner, 2026-10-31); the page lends it Today and "+".
    @ViewBuilder
    private func footer(_ snapshot: CalendarPageSnapshot) -> some View {
        let todayShown = CalendarTodayButton.isShown(selected: snapshot.selected, today: snapshot.today)
        ZStack {
            if sharedChrome == nil {
                ownFooter(snapshot)
            } else {
                // A view for the lending to hang on (an empty group has none).
                Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        .panelBottomBar(.calendar,
                        look: PanelBottomBarLook(middle: .today(shown: todayShown), plus: PanelBottomBarLook.calendarPlus),
                        actions: PanelBottomBarActions(today: { [model] in model.goToToday() },
                                                       plus: { [model] in onNewTask(model.newTaskDay) }))
    }

    private func ownFooter(_ snapshot: CalendarPageSnapshot) -> some View {
        let flat = design.effectiveControls != .liquidGlass
        let height = CalendarDesign.footerHeight
        return AtticControlGroup {
            HStack(spacing: TasksDesignMetrics.footerGap) {
                PanelPageSwitcher(page: .calendar)
                CalendarTodayButton(isShown: CalendarTodayButton.isShown(selected: snapshot.selected, today: snapshot.today),
                                    flat: flat, action: model.goToToday)
                Spacer(minLength: 0)
                AtticRaisedButton(systemName: "plus", label: "New task", size: CGSize(width: height, height: height),
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

/// The agenda's mask: everything shows until the selected week pins; then
/// what scrolls under the pinned week is hidden and fades in over
/// `CalendarDesign.agendaFade` below it (Accepted 2026-10-30, "Scrolling").
/// A static gradient: it changes only when the week pins or unpins.
/// The fade itself comes and goes in the hover motion (the design's quick
/// fade); the cut under the pinned week is immediate, as the pinned copy is.
struct CalendarScrollMask: View {
    let pinned: Bool

    @Environment(\.atticDesign) private var design

    #if DEBUG
    /// Test seam: the `pinned` of each body run, so a hosted test can see
    /// that the mounted scroller carries this mask and follows the pin.
    static var renders: [Bool] = []
    #endif

    var body: some View {
        #if DEBUG
        let _ = Self.renders.append(pinned)
        #endif
        VStack(spacing: 0) {
            Color.clear.frame(height: pinned ? CalendarDesign.weekPitch : 0)
            LinearGradient(colors: [.black.opacity(pinned ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                .frame(height: CalendarDesign.agendaFade)
                .animation(AtticMotionPreset.hover.animation(reduceMotion: design.reduceMotion), value: pinned)
            Color.black
        }
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
