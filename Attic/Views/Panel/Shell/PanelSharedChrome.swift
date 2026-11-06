import Combine
import SwiftUI

/// The controls every page shares, drawn once by the shell above the pages
/// (owner, 2026-10-31, Accepted "Shared controls stay still while pages
/// switch"): the bottom bar (the page switch, the tag bar card, "+") and
/// the top row's ••• and Search (the pin was already the shell's). A page
/// switch never moves, fades or rebuilds them; only what differs changes in
/// place (the tags in the tag bar, Calendar's Today, the search's label).
///
/// Each page still lays out its own bars, with clear stand-ins where the
/// shared controls sit (its list clearance and the composer's fold keep
/// their geometry), and lends the shell what its controls show and do
/// through this object. A page hosted alone (gallery, captures, tests) has
/// none in its environment and draws its own controls as before.
@MainActor
final class PanelSharedChrome: ObservableObject {
    /// What each page's bottom bar shows.
    @Published private(set) var bars: [PanelPage: PanelBottomBarLook] = [:]
    /// What each page's top row lends the shell (its search button).
    @Published private(set) var topRows: [PanelPage: PanelTopRowLook] = [:]
    /// The pages a task's page covers (its own bars replace the shared ones).
    @Published private(set) var covered: Set<PanelPage> = []
    /// The "+" card has the bar's row (Accepted 2026-11-03, P4): the bar's
    /// middle (the tag pills, Today) and "+" fade out under it as it opens
    /// and come back as it folds.
    @Published var plusHandedOver = false

    /// What the controls do, per page. Not observable: only a click reads them.
    private var barActions: [PanelPage: PanelBottomBarActions] = [:]
    private var searchActions: [PanelPage: () -> Void] = [:]
    private var moreCommands: [PanelPage: () -> [AtticMenuCommand]] = [:]

    // MARK: Bottom bar

    /// The page's bar; a page not built yet shows its usual controls, so a
    /// first switch to it never blinks the bar.
    func bar(for page: PanelPage) -> PanelBottomBarLook {
        var look = bars[page] ?? .placeholder(for: page)
        if covered.contains(page) { look.shown = false }
        return look
    }

    func barActions(for page: PanelPage) -> PanelBottomBarActions {
        barActions[page] ?? PanelBottomBarActions()
    }

    func setBar(_ look: PanelBottomBarLook, actions: PanelBottomBarActions, for page: PanelPage) {
        barActions[page] = actions
        if bars[page] != look { bars[page] = look }
    }

    func removeBar(for page: PanelPage) {
        barActions[page] = nil
        if bars[page] != nil { bars[page] = nil }
    }

    // MARK: Top row

    func topRow(for page: PanelPage) -> PanelTopRowLook {
        var look = topRows[page] ?? .placeholder(for: page)
        if covered.contains(page) { look.shown = false }
        return look
    }

    func setTopRowShown(_ shown: Bool, for page: PanelPage) {
        var look = topRows[page] ?? .placeholder(for: page)
        look.shown = shown
        if topRows[page] != look { topRows[page] = look }
    }

    func setSearch(label: String, identifier: String, action: @escaping () -> Void, for page: PanelPage) {
        searchActions[page] = action
        var look = topRows[page] ?? .placeholder(for: page)
        look.searchLabel = label
        look.searchIdentifier = identifier
        if topRows[page] != look { topRows[page] = look }
    }

    func search(on page: PanelPage) { searchActions[page]?() }

    /// What ••• offers on `page`, built when it opens.
    func setMore(_ commands: @escaping () -> [AtticMenuCommand], for page: PanelPage) {
        moreCommands[page] = commands
    }

    func more(on page: PanelPage) -> [AtticMenuCommand] { moreCommands[page]?() ?? [] }

    func removeTopRow(for page: PanelPage) {
        searchActions[page] = nil
        moreCommands[page] = nil
        if topRows[page] != nil { topRows[page] = nil }
    }

    // MARK: Covering

    func setCovered(_ isCovered: Bool, page: PanelPage) {
        if isCovered, !covered.contains(page) { covered.insert(page) }
        if !isCovered, covered.contains(page) { covered.remove(page) }
    }
}

/// What a page's bottom bar shows, beside the switch every bar starts with.
struct PanelBottomBarLook: Equatable {
    enum Middle: Equatable {
        case none
        /// The tag bar card: All and the tags; `shown` false fades it out
        /// in place, where Tasks' selection bar takes its turn (T2).
        case tags(tags: [String], selection: String?, idPrefix: String, shown: Bool)
        /// Calendar: Today, shown only while another day is selected.
        case today(shown: Bool)
    }

    struct Plus: Equatable {
        var label: String
        var help: String
        var identifier: String
    }

    var middle: Middle = .none
    var plus: Plus?
    /// Tasks' composer has the row: the switch and the middle fold away and
    /// "+" gives way to the page's add field.
    var folded = false
    /// Off while the page draws its own bar (an open note).
    var shown = true

    static let tasksPlus = Plus(label: String(localized: "New task"), help: String(localized: "New task"), identifier: "tasks-new-task")
    static let notesPlus = Plus(label: String(localized: "New note"), help: String(localized: "New note (⌘N)"), identifier: "notes-new-note")
    static let calendarPlus = Plus(label: String(localized: "New event"), help: String(localized: "New event"), identifier: "calendar-new-task")

    /// A page's bar before it reports: its usual controls, no tags yet.
    static func placeholder(for page: PanelPage) -> PanelBottomBarLook {
        switch page {
        case .tasks: PanelBottomBarLook(middle: .tags(tags: [], selection: nil, idPrefix: "tasks-tag-bar", shown: true), plus: tasksPlus)
        case .notes: PanelBottomBarLook(middle: .tags(tags: [], selection: nil, idPrefix: "notes-tag-bar", shown: true), plus: notesPlus)
        case .calendar: PanelBottomBarLook(middle: .none, plus: calendarPlus)
        case .canvas: AtticDraw.isEnabled ? PanelBottomBarLook(middle: .none, plus: PanelBottomBarLook.drawPlus) : PanelBottomBarLook()
        }
    }
}

struct PanelBottomBarActions {
    var selectTag: (String?) -> Void = { _ in }
    var today: () -> Void = {}
    var plus: () -> Void = {}
    /// The page's own Tab order, which reaches "+" after its last row.
    var focusRequests: AtticFocusRequests? = nil
}

/// The shared "+" as a stop in a page's Tab order (`TasksTabStop.plus`).
struct PanelPlusFocusID: Hashable {}

private struct PanelPlusFocus: ViewModifier {
    let requests: AtticFocusRequests?
    let action: () -> Void
    @FocusState private var focused: Bool
    /// Focusable only once the page's Tab asks for it, so the panel's own
    /// key loop (a reveal, a page switch) never lands on "+" by itself.
    @State private var armed = false

    /// One structure on every page (only Tasks lends its Tab order): a
    /// branch here would rebuild the "+" on each page switch.
    func body(content: Content) -> some View {
        content
            .focusable(armed && requests != nil, interactions: .activate)
            .focused($focused)
            .onKeyPress(keys: [.space, .return]) { _ in
                guard focused else { return .ignored }
                action()
                return .handled
            }
            .onReceive(requests?.requests.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { asked in
                guard asked == AnyHashable(PanelPlusFocusID()) else { return }
                armed = true
                DispatchQueue.main.async { focused = true }
            }
            .onChange(of: focused) { _, now in
                requests?.note(PanelPlusFocusID(), focused: now)
                if !now { armed = false }
            }
    }
}

/// What a page's top row lends the shell: whether it has one, and its
/// search button's words.
struct PanelTopRowLook: Equatable {
    var shown: Bool
    var searchLabel: String
    var searchIdentifier: String

    static func placeholder(for page: PanelPage) -> PanelTopRowLook {
        switch page {
        case .tasks: PanelTopRowLook(shown: true, searchLabel: String(localized: "Find (⌘F)"), searchIdentifier: "tasks-find-button")
        case .notes: PanelTopRowLook(shown: true, searchLabel: String(localized: "Search notes (⌘F)"), searchIdentifier: "notes-search-button")
        case .calendar: PanelTopRowLook(shown: true, searchLabel: String(localized: "Search"), searchIdentifier: "calendar-search-button")
        case .canvas: PanelTopRowLook(shown: AtticDraw.isEnabled, searchLabel: String(localized: "Search"),
                                      searchIdentifier: AtticDraw.isEnabled ? "draw-search-button" : "canvas-search-button")
        }
    }
}

private struct PanelSharedChromeKey: EnvironmentKey {
    static let defaultValue: PanelSharedChrome? = nil
}

extension EnvironmentValues {
    /// The shell's shared bars (nil where a page is hosted alone).
    var panelSharedChrome: PanelSharedChrome? {
        get { self[PanelSharedChromeKey.self] }
        set { self[PanelSharedChromeKey.self] = newValue }
    }
}

extension View {
    /// The page lends the shell's bottom bar what it shows and does. Written
    /// only when the look changes, never while laying out.
    func panelBottomBar(_ page: PanelPage, look: PanelBottomBarLook, actions: PanelBottomBarActions) -> some View {
        modifier(PanelBottomBarRegistration(page: page, look: look, actions: actions))
    }
}

private struct PanelBottomBarRegistration: ViewModifier {
    let page: PanelPage
    let look: PanelBottomBarLook
    let actions: PanelBottomBarActions

    @Environment(\.panelSharedChrome) private var chrome

    func body(content: Content) -> some View {
        content
            .onChange(of: look, initial: true) { _, look in chrome?.setBar(look, actions: actions, for: page) }
            .onDisappear { chrome?.removeBar(for: page) }
    }
}

// MARK: - The shared bottom bar

/// The bottom bar on every page (Built "Top row and bottom bar", as Accepted
/// 2026-10-31 "Tall island" updates it), drawn once: the page's middle on
/// the left (the tag bar card, or Calendar's Today), then "+". The page
/// switch left the bar for the island.
struct PanelSharedBottomBar: View {
    @ObservedObject var chrome: PanelSharedChrome
    let page: PanelPage
    let layout: PanelPageLayout

    @Environment(\.atticDesign) private var design

    #if DEBUG
    /// Test seam: how many times the bar's body has run.
    static var bodyEvaluations = 0
    /// Test seam: whether the bar drew its own "+" last time.
    static var drawsPlus = false
    #endif

    var body: some View {
        #if DEBUG
        let _ = Self.bodyEvaluations += 1
        #endif
        let look = chrome.bar(for: page)
        let actions = chrome.barActions(for: page)
        let side = AtticControlSize.headerControl
        let gap = TasksDesignMetrics.footerGap
        let folded = look.folded
        // A task page's own controls arrive at once. Its shared glass must
        // leave at once too; opacity outside a glass group cannot hide it.
        let covered = chrome.covered.contains(page)
        let taken = chrome.plusHandedOver || covered
        #if DEBUG
        let _ = Self.drawsPlus = look.plus != nil && !folded && !taken
        #endif
        HStack(alignment: .bottom, spacing: 0) {
            // P4: the card takes the row; the pills slide 6 pt toward the
            // bar's start as they fade (the design's 12 px). Their glass
            // goes too (a glass group ignores an opacity), so nothing
            // peeks out under the card's corners (Accepted 2026-11-04).
            PanelControlFold(folded: taken, animation: { covered ? nil : Self.rowAnimation(taken: $0, reduceMotion: design.reduceMotion) }) {
                HStack(spacing: gap) {
                    // Accessibility state goes on each control, never on this
                    // stack (which would make it an element wearing the
                    // switch's identifier).
                    middle(look.middle, actions: actions, hidden: folded || !look.shown || taken)
                }
            }
            .offset(x: taken ? -Self.takenSlide : 0)
            .animation(covered ? nil : Self.rowAnimation(taken: taken, reduceMotion: design.reduceMotion), value: taken)
            .frame(maxWidth: folded ? 0 : .infinity, alignment: .leading)
            .opacity(folded ? 0 : 1)
            .padding(.trailing, folded || look.plus == nil ? 0 : gap)
            .allowsHitTesting(!folded && !taken)
            if let plus = look.plus {
                ZStack(alignment: .bottomTrailing) {
                    if !folded {
                        PanelControlFold(folded: taken, animation: { covered ? nil : Self.rowAnimation(taken: $0, reduceMotion: design.reduceMotion) }) {
                            AtticRaisedButton(systemName: "plus", label: String.LocalizationValue(stringLiteral: plus.label), size: CGSize(width: side, height: side),
                                              help: plus.help, emphasisedGlyph: true,
                                              flat: design.effectiveControls != .liquidGlass, cornerRadius: AtticRadius.header,
                                              action: actions.plus)
                                .atticDesignCorners()
                                .modifier(PanelPlusFocus(requests: actions.focusRequests, action: actions.plus))
                        }
                            .allowsHitTesting(!taken)
                            .accessibilityIdentifier(plus.identifier)
                            .accessibilityHidden(!look.shown || taken)
                            .transition(.opacity)
                    }
                }
                .frame(width: folded ? nil : side, alignment: .trailing)
                .frame(maxWidth: folded ? .infinity : side, alignment: .trailing)
            }
        }
        .animation(TasksDesignMetrics.fold(reduceMotion: design.reduceMotion), value: folded)
        .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion, showing: todayShown(look)),
                   value: todayShown(look))
        .frame(height: side)
        .padding(.horizontal, Self.plusInsets(layout: layout).trailing)
        .padding(.bottom, Self.plusInsets(layout: layout).bottom)
        .opacity(look.shown ? 1 : 0)
        .allowsHitTesting(look.shown)
        .animation(covered ? nil : PanelTopRowLayout.searchAnimation(shown: look.shown, reduceMotion: design.reduceMotion), value: look.shown)
    }

    /// How far the pills move as the card takes the row (12 design px).
    static let takenSlide: CGFloat = 6
    /// The row going under the card: the quick leave. Coming back as the
    /// card folds: the popover's show, 90 ms in, so the pills return as the
    /// card has gone (the design's `transition-delay: 90ms`).
    static func rowAnimation(taken: Bool, reduceMotion: Bool) -> Animation? {
        let animation = AtticMotionPreset.popover.animation(reduceMotion: reduceMotion, showing: !taken)
        return taken || reduceMotion ? animation : animation?.delay(0.09)
    }

    /// Where the bar sits in the panel; the "+" card grows from this
    /// corner (`ComposerGrow.anchor`).
    static func plusInsets(layout: PanelPageLayout) -> EdgeInsets {
        let side = max(AtticSpacing.panelMargin, layout.chromeInsets.leading)
        return EdgeInsets(top: 0, leading: side, bottom: max(AtticSpacing.panelMargin, layout.chromeInsets.bottom),
                          trailing: side)
    }

    private func todayShown(_ look: PanelBottomBarLook) -> Bool {
        if case let .today(shown) = look.middle { shown } else { false }
    }

    @ViewBuilder
    private func middle(_ middle: PanelBottomBarLook.Middle, actions: PanelBottomBarActions, hidden: Bool) -> some View {
        switch middle {
        case .none:
            Spacer(minLength: 0)
        case let .tags(tags, selection, idPrefix, shown):
            PanelTagBar(tags: tags, selection: selection, idPrefix: idPrefix, onSelect: actions.selectTag)
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(shown)
                .accessibilityHidden(!shown || hidden)
                // Taking turns with the selection bar (T2), on its motion.
                .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion, showing: shown), value: shown)
                // Another page's middle (Calendar's Today) takes turns with
                // the tags, never cross-fading over them; between two pages
                // with tags the card itself stays.
                .transition(PanelTakeTurns.transition(reduceMotion: design.reduceMotion))
        case let .today(shown):
            // Built only while shown (the bar's outer accessibility state
            // must not reach a hidden Today), fading in and out on its own
            // motion as before; it takes turns with another page's tags.
            ZStack {
                if shown {
                    CalendarTodayButton(isShown: !hidden, flat: design.effectiveControls != .liquidGlass, action: actions.today)
                        .transition(.opacity)
                }
            }
            .transition(PanelTakeTurns.transition(reduceMotion: design.reduceMotion))
            Spacer(minLength: 0)
        }
    }
}

// MARK: - The shared top-row controls

/// ••• and Search at the top row's right, drawn once by the shell's header.
/// They fold away with the current page's search (the field grows from
/// Search's place, in the page) and while a task's page covers the page;
/// Canvas has neither.
struct PanelSharedTopControls: View {
    let page: PanelPage

    @Environment(\.panelSharedChrome) private var chrome
    @Environment(\.panelTopRowState) private var topRowState

    var body: some View {
        if let chrome, let topRowState {
            PanelSharedTopControlsObserver(chrome: chrome, state: topRowState, page: page)
        }
    }
}

private struct PanelSharedTopControlsObserver: View {
    @ObservedObject var chrome: PanelSharedChrome
    @ObservedObject var state: PanelTopRowState
    let page: PanelPage

    var body: some View {
        let look = chrome.topRow(for: page)
        let searching = state.isSearching(page)
        let covered = chrome.covered.contains(page)
        HStack(spacing: PanelTopRowLayout.gap) {
            PanelControlFold(folded: searching || !look.shown, animation: covered ? { _ in nil } : nil) {
                PanelTopRowMoreButton(shared: true, page: page) { chrome.more(on: page) }
            }
            PanelControlFold(folded: searching || !look.shown, animation: covered ? { _ in nil } : nil) {
                PanelTopRowSearchButton(label: look.searchLabel, identifier: look.searchIdentifier, shared: true) {
                    chrome.search(on: page)
                }
            }
        }
    }
}

/// A bottom row a page draws itself (an open note's, a task page's, the
/// selection bar) gives way to the "+" card as the shared bar does: the
/// card is translucent, so whatever stays in its row shows through at its
/// corners. Outside the panel there is no card and the row stays as it is.
private struct PanelRowGivesWayToCard: ViewModifier {
    @Environment(\.panelSharedChrome) private var chrome

    func body(content: Content) -> some View {
        if let chrome {
            Fold(chrome: chrome) { content }
        } else {
            content
        }
    }

    private struct Fold<Row: View>: View {
        @ObservedObject var chrome: PanelSharedChrome
        @ViewBuilder var row: () -> Row

        @Environment(\.atticDesign) private var design

        var body: some View {
            PanelControlFold(folded: chrome.plusHandedOver,
                             animation: { PanelSharedBottomBar.rowAnimation(taken: $0, reduceMotion: design.reduceMotion) },
                             content: row)
        }
    }
}

extension View {
    /// This row sits where the "+" card opens; it folds away under the card
    /// and comes back as the card folds (`PanelSharedChrome.plusHandedOver`).
    func panelRowGivesWayToCard() -> some View {
        modifier(PanelRowGivesWayToCard())
    }
}

/// A control in a glass group folding away and back in the search's motion:
/// the group ignores an opacity set on its members, so the glass fades
/// through `atticControlAway` and then goes (`atticControlGone`), as the
/// pin's does.
struct PanelControlFold<Content: View>: View {
    let folded: Bool
    /// The fold's motion, by `folded`: the search's unless given.
    var animation: ((Bool) -> Animation?)? = nil
    @ViewBuilder var content: () -> Content

    @Environment(\.atticDesign) private var design
    @State private var away = false
    @State private var gone = false

    var body: some View {
        content()
            .environment(\.atticControlAway, away)
            .environment(\.atticControlGone, gone)
            .opacity(folded ? 0 : 1)
            .allowsHitTesting(!folded)
            .accessibilityHidden(folded)
            .animation(animation(folded), value: folded)
            .onChange(of: folded, initial: true) { _, now in fold(now) }
    }

    /// The pin's: away on the search's opening ease, back on its quick fade.
    private func animation(_ folded: Bool) -> Animation? {
        if let animation = self.animation { return animation(folded) }
        return PanelTopRowLayout.searchAnimation(shown: folded, reduceMotion: design.reduceMotion)
    }

    private func fold(_ folded: Bool) {
        guard folded != away else { return }
        if folded {
            guard let animation = animation(true) else {
                away = true
                gone = true
                return
            }
            withAnimation(animation) { away = true } completion: { if away { gone = true } }
        } else {
            gone = false
            withAnimation(animation(false)) { away = false }
        }
    }
}
