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

    /// What the controls do, per page. Not observable: only a click reads them.
    private var barActions: [PanelPage: PanelBottomBarActions] = [:]
    private var searchActions: [PanelPage: () -> Void] = [:]

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

    func removeTopRow(for page: PanelPage) {
        searchActions[page] = nil
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
        /// The tag bar card: All and the tags; `shown` false keeps its
        /// place, empty (Tasks' Done).
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
    static let calendarPlus = Plus(label: String(localized: "New task"), help: String(localized: "New task"), identifier: "calendar-new-task")

    /// A page's bar before it reports: its usual controls, no tags yet.
    static func placeholder(for page: PanelPage) -> PanelBottomBarLook {
        switch page {
        case .tasks: PanelBottomBarLook(middle: .tags(tags: [], selection: nil, idPrefix: "tasks-tag-bar", shown: true), plus: tasksPlus)
        case .notes: PanelBottomBarLook(middle: .tags(tags: [], selection: nil, idPrefix: "notes-tag-bar", shown: true), plus: notesPlus)
        case .calendar: PanelBottomBarLook(middle: .today(shown: false), plus: calendarPlus)
        case .canvas: PanelBottomBarLook()
        }
    }
}

struct PanelBottomBarActions {
    var selectTag: (String?) -> Void = { _ in }
    var today: () -> Void = {}
    var plus: () -> Void = {}
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
        case .canvas: PanelTopRowLook(shown: false, searchLabel: String(localized: "Search"), searchIdentifier: "canvas-search-button")
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

/// The bottom bar on every page (Accepted 2026-10-29/30, "Top row and bottom
/// bar"), drawn once: the page switch, the page's middle (the tag bar card,
/// or Calendar's Today), then "+". The switch opens on hover and pushes the
/// rest along in its own transaction, so the bar's leading edge follows it
/// on every frame.
struct PanelSharedBottomBar: View {
    @ObservedObject var chrome: PanelSharedChrome
    let page: PanelPage
    let layout: PanelPageLayout

    @Environment(\.atticDesign) private var design

    #if DEBUG
    /// Test seam: how many times the bar's body has run.
    static var bodyEvaluations = 0
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
        HStack(alignment: .bottom, spacing: 0) {
            HStack(spacing: gap) {
                // Accessibility state goes on each control, never on this
                // stack (which would make it an element wearing the
                // switch's identifier).
                PanelPageSwitcher(page: page)
                    .accessibilityHidden(folded || !look.shown)
                middle(look.middle, actions: actions, hidden: folded || !look.shown)
            }
            .frame(maxWidth: folded ? 0 : .infinity, alignment: .leading)
            .opacity(folded ? 0 : 1)
            .padding(.trailing, folded || look.plus == nil ? 0 : gap)
            .allowsHitTesting(!folded)
            if let plus = look.plus {
                ZStack(alignment: .bottomTrailing) {
                    if !folded {
                        AtticRaisedButton(systemName: "plus", label: String.LocalizationValue(stringLiteral: plus.label), size: CGSize(width: side, height: side),
                                          help: plus.help, emphasisedGlyph: true,
                                          flat: design.effectiveControls != .liquidGlass, cornerRadius: AtticRadius.header,
                                          action: actions.plus)
                            .atticDesignCorners()
                            .accessibilityIdentifier(plus.identifier)
                            .accessibilityHidden(!look.shown)
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
        .animation(PanelTopRowLayout.searchAnimation(shown: look.shown, reduceMotion: design.reduceMotion), value: look.shown)
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
        case let .today(shown):
            // Built only while shown (the bar's outer accessibility state
            // must not reach a hidden Today), fading in and out on its own
            // motion as before.
            if shown {
                CalendarTodayButton(isShown: !hidden, flat: design.effectiveControls != .liquidGlass, action: actions.today)
                    .transition(.opacity)
            }
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
        HStack(spacing: PanelTopRowLayout.gap) {
            PanelControlFold(folded: searching || !look.shown) {
                PanelTopRowMoreButton(shared: true)
            }
            PanelControlFold(folded: searching || !look.shown) {
                PanelTopRowSearchButton(label: look.searchLabel, identifier: look.searchIdentifier, shared: true) {
                    chrome.search(on: page)
                }
            }
        }
    }
}

/// A control in a glass group folding away and back in the search's motion:
/// the group ignores an opacity set on its members, so the glass fades
/// through `atticControlAway` and then goes (`atticControlGone`), as the
/// pin's does.
struct PanelControlFold<Content: View>: View {
    let folded: Bool
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
    private func animation(_ folded: Bool) -> Animation {
        PanelTopRowLayout.searchAnimation(shown: folded, reduceMotion: design.reduceMotion)
    }

    private func fold(_ folded: Bool) {
        guard folded != away else { return }
        if folded {
            withAnimation(animation(true)) { away = true } completion: { if away { gone = true } }
        } else {
            gone = false
            withAnimation(animation(false)) { away = false }
        }
    }
}
