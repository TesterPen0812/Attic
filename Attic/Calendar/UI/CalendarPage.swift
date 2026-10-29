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
    @State private var scrollPosition = ScrollPosition(y: 0)
    @State private var flags = ScrollFlags()
    @State private var searchOpen = false
    @State private var searchFocused = false

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
        .onChange(of: snapshot.weeks.count) { _, count in
            // The week view stays the week view when the month changes
            // (a month of another length has another offset).
            if flags.weekView { scrollPosition.scrollTo(y: CalendarMonthMath.weekViewOffset(weekCount: count)) }
        }
        .accessibilityIdentifier("calendar-page")
    }

    // MARK: Scrolling grid and agenda

    private func scroller(_ snapshot: CalendarPageSnapshot, viewport: CGFloat) -> some View {
        let weeks = snapshot.weeks
        let pinnedIndex = snapshot.pinnedWeekIndex
        return ScrollView(.vertical) {
            VStack(spacing: 0) {
                AtticControlGroup {
                    VStack(spacing: 0) {
                        ForEach(weeks) { week in
                            CalendarWeekRow(week: week, isWeekView: flags.weekView, onSelect: model.select)
                                .equatable()
                        }
                    }
                }
                agenda(snapshot)
                    .frame(minHeight: viewport, alignment: .top)
            }
            .padding(.bottom, CalendarDesign.agendaBottom)
        }
        .scrollIndicators(.never)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: ScrollFlags.self) { geometry in
            let offset = geometry.contentOffset.y + geometry.contentInsets.top
            return ScrollFlags(pinned: CalendarMonthMath.isPinned(offset: offset, pinnedIndex: pinnedIndex),
                               weekView: CalendarMonthMath.isWeekView(offset: offset, weekCount: weeks.count))
        } action: { _, new in
            if flags != new { flags = new }
        }
        // While the selected week is pinned, what scrolls under it is cut at
        // its bottom edge, and its copy stays put above.
        .mask(alignment: .top) {
            VStack(spacing: 0) {
                Color.clear.frame(height: flags.pinned ? CalendarDesign.weekPitch : 0)
                Color.black
            }
        }
        .overlay(alignment: .top) {
            if flags.pinned, let pinnedIndex, weeks.indices.contains(pinnedIndex) {
                AtticControlGroup {
                    CalendarWeekRow(week: weeks[pinnedIndex], isWeekView: flags.weekView, onSelect: model.select)
                        .equatable()
                }
            }
        }
        .accessibilityIdentifier("calendar-scroll")
    }

    @ViewBuilder
    private func agenda(_ snapshot: CalendarPageSnapshot) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(snapshot.groups) { group in
                CalendarAgendaDay(group: group, today: snapshot.today, taskActions: taskActions,
                                  onSelectDay: model.select)
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

    /// Between the shell's pin and page switch: the month controls, then
    /// Search. Opening Search widens the field over the month controls,
    /// which fade out.
    private func topRow(_ snapshot: CalendarPageSnapshot) -> some View {
        let chrome = layout.chromeInsets
        let control = AtticControlSize.headerControl
        let flat = design.effectiveControls != .liquidGlass
        return ZStack(alignment: .trailing) {
            CalendarTopRowControls(month: snapshot.month, isWeekView: flags.weekView,
                                   onToggleWeekView: { toggleWeekView(weekCount: snapshot.weeks.count) },
                                   onPrevious: { model.shift(by: -1, weekView: flags.weekView) },
                                   onNext: { model.shift(by: 1, weekView: flags.weekView) })
                .padding(.trailing, control + CalendarDesign.controlsGap)
                .opacity(searchOpen ? 0 : 1)
                .allowsHitTesting(!searchOpen)
                .accessibilityHidden(searchOpen)
            if searchOpen {
                AtticTabsSearchField(placeholder: String(localized: "Search"),
                                     text: Binding(get: { model.searchText }, set: { model.setQuery($0) }),
                                     isFocused: $searchFocused, floating: true, onEscape: endSearch, header: true)
                    .atticDesignCorners()
                    .accessibilityIdentifier("calendar-search")
                    .transition(.asymmetric(insertion: .scale(scale: 0.2, anchor: .trailing).combined(with: .opacity),
                                            removal: .opacity))
            } else {
                AtticRaisedButton(systemName: "magnifyingglass", label: "Search",
                                  size: CGSize(width: control, height: control), emphasisedGlyph: true, flat: flat,
                                  cornerRadius: AtticRadius.header, action: beginSearch)
                    .atticDesignCorners()
                    .accessibilityIdentifier("calendar-search-button")
                    .transition(.opacity)
            }
        }
        .frame(height: control)
        .padding(.top, chrome.top)
        .padding(.leading, chrome.leading + control + TasksDesignMetrics.searchFromPin)
        .padding(.trailing, chrome.trailing + AtticPageButton<PanelPage>.width(open: false, count: PanelPage.allCases.count)
                 + TasksDesignMetrics.headerGap)
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

    private func footer(_ snapshot: CalendarPageSnapshot) -> some View {
        let tokens = design.tokens
        let flat = design.effectiveControls != .liquidGlass
        let onToday = snapshot.selected == snapshot.today
        let height = CalendarDesign.footerHeight
        return AtticControlGroup {
            HStack(spacing: TasksDesignMetrics.footerGap) {
                Button {
                    model.goToToday()
                } label: {
                    Text("Today")
                        .font(.system(size: CalendarDesign.todayFont, weight: .medium))
                        .foregroundStyle(onToday ? TasksPanelDesign.toneInk(.meta, tokens: tokens).color : tokens.ink(.heading).color)
                        .padding(.horizontal, CalendarDesign.todayPaddingX)
                        .frame(height: height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(AtticRaisedButtonStyle(cornerRadius: TasksDesignMetrics.footerRadius, flat: flat))
                .focusEffectDisabled()
                .help(String(localized: "Go to today"))
                .accessibilityIdentifier("calendar-today")
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
