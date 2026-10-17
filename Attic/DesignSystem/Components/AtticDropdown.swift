import AppKit
import SwiftUI

// MARK: - Attic's own dropdowns (E1)

// The one pop-over list Attic draws itself (owner, 2026-10-02: E1 of
// mockup p2-25, with p2-24 D's rows and p2-23's width rule): the `/` list,
// the date card (Notes and Tasks), the tag and priority pickers, Aa and the
// link card. Native menus (right-click, ⋯, the menu bar) stay native.
//
// - `AtticDropdownCard`: the solid card (no blur), one hairline, D's shadow,
//   16 pt corners, rows 6 pt in (the Compact size, p2-28).
// - `AtticDropdownRow`: a 28 pt row, touching its neighbours; the pill is the
//   whole row. One highlight per list, which the keyboard and the pointer
//   share (`onHover` moves the list's).
// - `AtticDropdownField`: the card's field (Find or add a tag, the date).
// - `AtticDropdownLayout`: the width rule and where the card opens;
//   `AtticDropdownLayout.place` and `AtticDropdownSpace` are the one
//   placement every card uses (the presenter's, the `/` list, Notes' date
//   and link cards, the title's tag suggestions).
// - `atticDropdown(isPresented:…)`: shows a card in the panel's overlay
//   layer, so opening, filtering and closing it never re-render the page
//   behind it.
//
// Every value is in `AtticDropdownMetrics` and the colour tokens
// (`popoverFill`, `popoverOuterRim`, `dropdownHighlight`, `dropdownShadow`,
// `dropdownContactShadow`).

/// The card's face: a solid fill, one hairline just outside it (Attic's
/// outer-rim token, 1 pt under Increase Contrast) and D's two shadows. Solid,
/// so Reduce Transparency changes nothing.
///
/// While the card unfolds (`AtticDropdownReveal`) the face is drawn at the
/// revealed height, so its corners, hairline and shadow travel with it.
struct AtticDropdownSurface: View {
    @Environment(\.atticDesign) private var design
    @Environment(\.atticUnfold) private var unfold

    var body: some View {
        let tokens = design.tokens
        let shape = AtticUnfoldShape(cornerRadius: AtticDropdownMetrics.cornerRadius, reveal: unfold?.reveal ?? 1,
                                     fromTop: unfold?.fromTop ?? true)
        let edge = design.increaseContrast ? AtticHairline.widthIncreased : AtticHairline.width
        let shadow = Double(unfold?.shadow ?? 1)
        ZStack {
            AtticOutsideShadow(shape: shape, color: tokens.dropdownShadow.withAlpha(tokens.dropdownShadow.alpha * shadow),
                               spec: AtticShadows.dropdown)
            AtticOutsideShadow(shape: shape, color: tokens.dropdownContactShadow.withAlpha(tokens.dropdownContactShadow.alpha * shadow),
                               spec: AtticShadows.dropdownContact)
            shape.fill(tokens.popoverFill.color)
            // CSS's `0 0 0 .5px`: a ring wholly outside the fill.
            shape.inset(by: -edge / 2).stroke(tokens.popoverOuterRim.color, lineWidth: edge)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The card: its rows or fields 6 pt in, on `AtticDropdownSurface`. With
/// no `width` it is as wide as its content, never under 144 pt; the
/// presenter caps it at the panel's margin (`AtticDropdownLayout.width`).
struct AtticDropdownCard<Content: View>: View {
    var width: CGFloat?
    @Environment(\.atticDropdownHeight) private var height
    @Environment(\.atticDropdownWidth) private var widthLimit
    @Environment(\.atticDropdownContentHeightChanged) private var heightChanged
    @Environment(\.atticDropdownContentWidthChanged) private var widthChanged
    @ViewBuilder let content: Content

    init(width: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.width = width
        self.content = content()
    }

    var body: some View {
        let m = AtticDropdownMetrics.self
        AtticDropdownViewport(height: height.map { max(0, $0 - m.inset * 2) }, persistent: heightChanged != nil) {
            VStack(alignment: .leading, spacing: 0) { content }
                .modifier(AtticDropdownHeightObserver(changed: heightChanged))
                .modifier(AtticDropdownWidthObserver(changed: widthChanged))
        }
            .padding(m.inset)
            .frame(minWidth: width == nil ? m.minWidth : nil, alignment: .leading)
            .frame(width: widthLimit ?? width, alignment: .leading)
            .background(AtticDropdownSurface())
            .modifier(AtticUnfoldCard(cornerRadius: m.cornerRadius))
    }
}

/// Reports a measured card's natural height: its content's laid-out height
/// plus what any part of it gave up to fit the card's limit
/// (`atticDropdownHeightGivenUp`, the tag picker's shortened list). Both
/// arrive as one preference value, in the same pass, so a constrained card
/// never reports its constrained height as natural (P3-B2: a picker taller
/// than both sides flickered `nil → 178 → nil → 178` as it opened).
/// Known-height lists avoid observation work on their open/filter path.
private struct AtticDropdownHeightObserver: ViewModifier {
    var changed: ((CGFloat) -> Void)?
    @State private var reporter = AtticDropdownHeightReporter()

    func body(content: Content) -> some View {
        if let changed {
            content
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: AtticDropdownNaturalHeightKey.self, value: proxy.size.height)
                })
                .onPreferenceChange(AtticDropdownNaturalHeightKey.self) { [reporter] height in
                    MainActor.assumeIsolated {
                        reporter.report(height + AtticDropdownMetrics.inset * 2, to: changed)
                    }
                }
        } else {
            content
        }
    }
}

/// Defers AppKit placement past layout, once per turn, with the latest
/// height (an intermediate value is never placed).
@MainActor
private final class AtticDropdownHeightReporter {
    private var latest: CGFloat?

    func report(_ height: CGFloat, to changed: @escaping (CGFloat) -> Void) {
        let scheduled = latest != nil
        latest = height
        guard !scheduled else { return }
        DispatchQueue.main.async { [self] in
            guard let height = latest else { return }
            latest = nil
            changed(height)
        }
    }
}

/// Reports the widest row a measured card's content asks for
/// (`atticDropdownIdealWidth`), as a card width, once per turn: a row that
/// appears while filtering (the tag picker's "New tag “#…”") widens the card
/// instead of being cut short at the width it opened with (CU P3-03).
private struct AtticDropdownWidthObserver: ViewModifier {
    var changed: ((CGFloat) -> Void)?
    @State private var reporter = AtticDropdownHeightReporter()

    func body(content: Content) -> some View {
        if let changed {
            content.onPreferenceChange(AtticDropdownIdealWidthKey.self) { [reporter] width in
                MainActor.assumeIsolated {
                    guard width > 0 else { return }
                    reporter.report(width + AtticDropdownMetrics.inset * 2, to: changed)
                }
            }
        } else {
            content
        }
    }
}

/// The widest row of a card's content, its insets excluded (0: not known).
struct AtticDropdownIdealWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A measured card's natural content height: the laid-out height, plus the
/// height any part gave up to fit the card's limit.
struct AtticDropdownNaturalHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

extension View {
    /// The height this part of a measured card gave up to fit the card's
    /// limit (`atticDropdownHeight`), so the card still knows its natural
    /// height.
    func atticDropdownHeightGivenUp(_ height: CGFloat) -> some View {
        preference(key: AtticDropdownNaturalHeightKey.self, value: max(0, height))
    }

    /// The width this part of a card's content needs (its widest row, the
    /// card's insets excluded): an open card grows to it, never shrinks.
    func atticDropdownIdealWidth(_ width: CGFloat) -> some View {
        preference(key: AtticDropdownIdealWidthKey.self, value: max(0, width))
    }
}

extension View {
    /// A dropdown's rows as one keyboard stop, as a native menu's or
    /// list's are: with Full Keyboard Access, Tab (and Shift-Tab) reach the
    /// list, never each row, and arriving puts the list's one highlight on
    /// its first row when it has none. The list's keys (↑ ↓, Return, and
    /// Space while the list has the keyboard) move and press that
    /// highlight; the pill is the keyboard's place, so the list draws no
    /// ring of its own. Like a button, the list is a stop only under Full
    /// Keyboard Access, and a click never moves the keyboard to it (the
    /// field keeps typing).
    func atticDropdownList(focus: FocusState<AtticDropdownFocusTarget?>.Binding, highlighted: Binding<Int?>, count: Int) -> some View {
        modifier(AtticDropdownListFocus(focus: focus, highlighted: highlighted, count: count))
    }
}

/// Which part of a card with a field and a list has the keyboard. One
/// focus value for both, so they can never both ask for it: two Bool
/// focus states, each written separately, raced under Full Keyboard Access
/// (H5-04).
enum AtticDropdownFocusTarget: Hashable {
    case field, list
}

extension View {
    /// Tab and Shift-Tab in a card with a field and a list: the keyboard
    /// moves between the two and never leaves the card, as in a native
    /// menu. The list is a stop only under Full Keyboard Access; otherwise
    /// Tab keeps the caret in the field. The card takes Tab before the
    /// field's editor does (`atticDropdownRegisterKeys`): left to the
    /// window's key-view loop, Tab from the field gave the keyboard to the
    /// card's host view, which cleared SwiftUI's focus, so the rows were
    /// never reached and Space pressed nothing (CI, Full Keyboard Access).
    /// `count` is the list's rows: an empty list is no stop.
    func atticDropdownTabs(focus: FocusState<AtticDropdownFocusTarget?>.Binding, count: Int) -> some View {
        modifier(AtticDropdownTabs(focus: focus, count: count))
    }
}

enum AtticDropdownTabFocus {
    /// Where Tab (or Shift-Tab) moves the keyboard from `current`; nil:
    /// it stays where it is.
    static func next(from current: AtticDropdownFocusTarget?, fullKeyboardAccess: Bool,
                     listAvailable: Bool) -> AtticDropdownFocusTarget? {
        if current == .list { return .field }
        return fullKeyboardAccess && listAvailable ? .list : nil
    }
}

private struct AtticDropdownTabs: ViewModifier {
    var focus: FocusState<AtticDropdownFocusTarget?>.Binding
    let count: Int
    @Environment(\.atticDropdownRegisterKeys) private var registerKeys

    func body(content: Content) -> some View {
        content
            .onAppear(perform: registerTabKeys)
            .onChange(of: count) { _, _ in registerTabKeys() }
            .onDisappear { registerKeys(nil) }
    }

    private func registerTabKeys() {
        let focus = focus, listAvailable = count > 0
        registerKeys { event in
            guard event.keyCode == 48,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
            if let next = AtticDropdownTabFocus.next(from: focus.wrappedValue,
                                                     fullKeyboardAccess: NSApp.isFullKeyboardAccessEnabled,
                                                     listAvailable: listAvailable) {
                focus.wrappedValue = next
            }
            return true
        }
    }
}

private struct AtticDropdownListFocus: ViewModifier {
    var focus: FocusState<AtticDropdownFocusTarget?>.Binding
    @Binding var highlighted: Int?
    let count: Int

    func body(content: Content) -> some View {
        content
            .focusable(count > 0, interactions: .activate)
            .focused(focus, equals: .list)
            .focusEffectDisabled()
            .onChange(of: focus.wrappedValue == .list) { _, now in
                if now, highlighted == nil, count > 0 { highlighted = 0 }
            }
    }
}

/// A quiet gap between a card's groups (space, never a line).
struct AtticDropdownGap: View {
    var height: CGFloat = AtticDropdownMetrics.groupGap

    var body: some View { Color.clear.frame(height: height).accessibilityHidden(true) }
}

/// One row of a dropdown (p2-24 D, Compact size): 28 pt, touching; an
/// optional check column, a priority's mark, a 13 pt icon in a 16 pt slot,
/// the 13 pt name and a short trailing detail (⌥⌘2, 2 Oct). Never a hint column.
///
/// One highlight (fix 1): a list with a keyboard highlight owns it and the
/// pointer moves it (`onHover`), as in a native menu; with no `onHover` the
/// row lights while hovered.
/// A tag row's inline colour dot: an image as wide as the dot column and
/// the gap after it, the 7 pt dot centred in the column on the capitals'
/// middle (it sits on the baseline in the text).
@MainActor
enum AtticDropdownDot {
    private static var cache: [NSColor: NSImage] = [:]

    static func image(_ color: NSColor, font: NSFont) -> NSImage {
        if let image = cache[color] { return image }
        let m = AtticDropdownMetrics.self
        let height = max(m.dotSize, font.capHeight)
        let image = NSImage(size: NSSize(width: m.dotSlot + m.columnGap, height: height), flipped: false) { _ in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: (m.dotSlot - m.dotSize) / 2, y: (height - m.dotSize) / 2,
                                        width: m.dotSize, height: m.dotSize)).fill()
            return true
        }
        cache[color] = image
        return image
    }
}

/// Shortcut hints in Attic's own menus (O14-08, owner 2026-10-14: "you
/// don't need to have these controls visible all the time"): a row's
/// shortcut (⌥⌘1) is hidden until ⌥ is held, fades in while it is and out
/// on release. The shortcuts themselves always work. One shared watch of
/// the modifier keys, kept only while a hint is on screen.
#if DEBUG
/// Buffered counters for the opening-cost diagnostic; no logging in timed work.
@MainActor
enum AtticDropdownDiagnostics {
    static var enabled = false
    static var layouts = 0
    static var hintRetains = 0
    static var reveals = 0
}
#endif

@MainActor
final class AtticOptionHints: ObservableObject {
    static let shared = AtticOptionHints()

    /// The hints show (⌥ is held).
    @Published private(set) var shown = false

    private var users = 0
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    /// A trailing detail that is a keyboard shortcut ("⌥⌘2", "⇧⌘K"), not
    /// a date or a count.
    nonisolated static func isShortcut(_ text: String) -> Bool {
        text.contains { "⌘⌥⌃⇧".contains($0) }
    }

    #if DEBUG
    /// Capture seam (`ATTIC_UI_TEST_OPTION_HELD=1`, UI testing in a preview
    /// identity only): the hints show as if ⌥ were held.
    nonisolated static let forced: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["ATTIC_UI_TESTING"] == "1" && environment["ATTIC_UI_TEST_OPTION_HELD"] == "1"
            && AtticPreviewOverrides.isPreviewIdentity(Bundle.main.bundleIdentifier)
    }()
    #else
    nonisolated static let forced = false
    #endif

    func update(_ flags: NSEvent.ModifierFlags) {
        let held = flags.intersection(.deviceIndependentFlagsMask).contains(.option)
        if held != shown { shown = held }
    }

    /// A hint appeared: watch ⌥ while any hint shows.
    func retain() {
        #if DEBUG
        if AtticDropdownDiagnostics.enabled { AtticDropdownDiagnostics.hintRetains += 1 }
        #endif
        users += 1
        guard users == 1 else { return }
        update(Self.forced ? .option : NSEvent.modifierFlags)
        guard !Self.forced else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.update(event.modifierFlags) }
            return event
        }
        // ⌥ let go in another app never reaches this one.
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update([]) }
            })
        }
    }

    func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        update([])
    }
}

/// Opt in only around menus with shortcuts: one observation and lifetime.
/// Leaves receive a plain value rather than observing shared or environment state.
struct AtticShortcutHintScope<Content: View>: View {
    @ObservedObject private var hints = AtticOptionHints.shared
    let content: (Bool) -> Content

    init(@ViewBuilder content: @escaping (Bool) -> Content) { self.content = content }

    var body: some View {
        content(hints.shown)
            .onAppear { hints.retain() }
            .onDisappear { hints.release() }
    }
}

/// Standalone hints retain their existing observation and lifetime.
struct AtticShortcutHint: View {
    let text: String
    @ObservedObject private var hints = AtticOptionHints.shared

    var body: some View {
        AtticText(verbatim: text, style: .shortcut, ink: .helper)
            .fixedSize()
            .opacity(hints.shown ? 1 : 0)
            .animation(AtticMotionScale.easeOut(AtticMotionScale.fast), value: hints.shown)
            .onAppear { hints.retain() }
            .onDisappear { hints.release() }
    }
}

private struct AtticShortcutHintText: View {
    let text: String
    let shown: Bool

    var body: some View {
        AtticText(verbatim: text, style: .shortcut, ink: .helper)
            .fixedSize()
            .opacity(shown ? 1 : 0)
            .animation(AtticMotionScale.easeOut(AtticMotionScale.fast), value: shown)
    }
}

struct AtticDropdownRow: View {
    let title: String
    var systemName: String?
    /// nil: no check column. The tick sits after the item, at the row's
    /// end (N-4's card design, owner 2026-10-11: on every dropdown).
    var check: AtticCheckState?
    /// A colour dot before the name (a tag's hue).
    var dot: AtticInk?
    /// A glyph in the dot's column of a row that has no dot (the tag
    /// picker's "New tag" +), so its name starts where the tags' do.
    var checkGlyph: String?
    /// A priority's mark column (`.none` keeps the column empty).
    var mark: AtticPriority?
    var detail: String?
    /// Only a shortcut menu's shared scope supplies this value.
    var shortcutHintsShown: Bool?
    /// Typed text to embolden in the name (the `/` list's filter).
    var match: String?
    var scrollID: String?
    var position: Int?
    var itemCount: Int?
    var isHighlighted = false
    var titleInk: AtticInk = .body
    /// The name in its own font (the style list: each style in its style).
    var titleFont: Font?
    var onHover: ((Bool) -> Void)?
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var hovered = false

    init(title: String, systemName: String? = nil, check: AtticCheckState? = nil, dot: AtticInk? = nil, checkGlyph: String? = nil,
         mark: AtticPriority? = nil,
         detail: String? = nil, shortcutHintsShown: Bool? = nil, match: String? = nil, isHighlighted: Bool = false, titleInk: AtticInk = .body,
         titleFont: Font? = nil, onHover: ((Bool) -> Void)? = nil, position: Int? = nil, itemCount: Int? = nil, scrollID: String? = nil, action: @escaping () -> Void) {
        self.scrollID = scrollID
        self.position = position
        self.itemCount = itemCount
        self.title = title
        self.systemName = systemName
        self.check = check
        self.dot = dot
        self.checkGlyph = checkGlyph
        self.mark = mark
        self.detail = detail
        self.shortcutHintsShown = shortcutHintsShown
        self.match = match
        self.isHighlighted = isHighlighted
        self.titleInk = titleInk
        self.titleFont = titleFont
        self.onHover = onHover
        self.action = action
    }

    /// The row is lit: the list's highlight, or its own hover in a list
    /// without one.
    static func isLit(highlighted: Bool, hovered: Bool, listOwnsHighlight: Bool) -> Bool {
        listOwnsHighlight ? highlighted : (highlighted || hovered)
    }

    var body: some View {
        let m = AtticDropdownMetrics.self
        let tokens = design.tokens
        let lit = Self.isLit(highlighted: isHighlighted, hovered: hovered, listOwnsHighlight: onHover != nil)
        let pill = RoundedRectangle(cornerRadius: m.highlightRadius, style: .continuous)
        Button(action: action) {
            HStack(spacing: 0) {
                HStack(spacing: m.columnGap) {
                    if dot != nil, titleFont == nil, match?.isEmpty ?? true {
                        // The dot is set inline in the name's own text (one
                        // view per row: the tag picker opens with a row per
                        // tag and its open cost is gated).
                        dottedName
                    } else if let checkGlyph {
                        AtticIcon(systemName: checkGlyph, size: m.checkSize, weight: .semibold, ink: .glyph)
                            .frame(width: m.dotSlot)
                    }
                    if let mark {
                        // None keeps the column (U-15): an empty mark is
                        // EmptyView, which a frame alone would not hold open.
                        ZStack { AtticPriorityMark(priority: mark) }
                            .frame(width: m.markSlot)
                    }
                    if let systemName {
                        AtticIcon(systemName: systemName, size: m.iconSize, ink: .icon)
                            .frame(width: m.iconSlot)
                    }
                    if !(dot != nil && titleFont == nil && (match?.isEmpty ?? true)) {
                        name
                    }
                }
                Spacer(minLength: detail == nil ? (check == nil ? 0 : m.columnGap) : m.detailGap)
                if let detail {
                    if AtticOptionHints.isShortcut(detail) {
                        // O14-08: shortcuts show while ⌥ is held.
                        if let shortcutHintsShown {
                            AtticShortcutHintText(text: detail, shown: shortcutHintsShown)
                        } else {
                            AtticShortcutHint(text: detail)
                        }
                    } else {
                        AtticText(verbatim: detail, style: .shortcut, ink: .helper)
                            .fixedSize()
                    }
                }
                // An unticked row draws nothing there: its column is room the
                // card's width already keeps (the tag picker opens with a row
                // per tag, so every view a row saves counts).
                if let check, check != .off {
                    AtticIcon(systemName: check == .on ? "checkmark" : "minus", size: m.checkSize, weight: .semibold, ink: .glyph)
                        .frame(width: m.checkSlot)
                        .padding(.leading, detail == nil ? 0 : m.columnGap)
                } else if check == .off, detail != nil {
                    // Details stay in one column, ticked or not.
                    Color.clear.frame(width: m.checkSlot + m.columnGap, height: 1)
                }
            }
            .padding(.horizontal, m.rowPadding)
            .frame(height: m.rowHeight)
            .background(pill.fill((lit ? tokens.dropdownHighlight : .clear).color))
            .contentShape(Rectangle())
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        // Never its own Tab stop: a list's rows are one keyboard stop, as a
        // native menu's are (`atticDropdownList`), and the one highlight
        // shows where the keyboard is. Under Full Keyboard Access a row
        // took Tab as a button but its Space reached nothing.
        .focusable(false)
        .focusEffectDisabled()
        // The whole row answers the pointer (no dead gap between rows). A
        // row sliding under a resting pointer as the keyboard scrolls the
        // list is not the pointer moving: the keyboard keeps its highlight.
        .onContinuousHover { phase in
            switch phase {
            case .active:
                guard AtticListHighlight.isPointerMove(NSApp.currentEvent) else { return }
                if !hovered { hovered = true }
                onHover?(true)
            case .ended:
                if hovered { hovered = false }
                onHover?(false)
            }
        }
        .id(scrollID ?? title)
        .preference(key: AtticDropdownHighlightKey.self, value: isHighlighted ? (scrollID ?? title) : nil)
        // VoiceOver's "selected" is the one highlight; the tick is the menu
        // item's own mark, as in a native menu.
        .accessibilityRepresentation {
            AtticDropdownMenuItem(label: detail.map { "\(title), \($0)" } ?? title,
                                  selected: isHighlighted, check: check,
                                  position: position, count: itemCount, action: action)
        }
    }

    /// A tag row's name with its colour dot set before it, in one text: the
    /// dot's image is the dot column and the gap wide, so the name starts
    /// where the "New tag" row's does.
    private var dottedName: some View {
        let style = AtticTextStyle.dropdownRow
        let color = design.tokens.color(dot ?? titleInk)
        return (Text(Image(nsImage: AtticDropdownDot.image(NSColor(color), font: style.nsFont))) + Text(verbatim: title))
            .font(style.font)
            .foregroundStyle(design.tokens.color(titleInk))
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityLabel(title)
    }

    @ViewBuilder
    private var name: some View {
        if let titleFont {
            Text(title)
                .font(titleFont)
                .foregroundStyle(design.tokens.color(titleInk))
                .lineLimit(1)
                .fixedSize()
        } else if let match, !match.isEmpty, let range = title.range(of: match, options: [.caseInsensitive, .diacriticInsensitive]) {
            Text(Self.emboldened(title, range: range))
                .font(AtticTextStyle.dropdownRow.font)
                .foregroundStyle(design.tokens.color(titleInk))
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            AtticText(verbatim: title, style: .dropdownRow, ink: titleInk, truncates: true)
        }
    }

    private static func emboldened(_ title: String, range: Range<String.Index>) -> AttributedString {
        var string = AttributedString(title)
        if let lower = AttributedString.Index(range.lowerBound, within: string),
           let upper = AttributedString.Index(range.upperBound, within: string) {
            string[lower..<upper].font = .system(size: AtticTextStyle.dropdownHeading.spec.size,
                                                 weight: AtticTextStyle.dropdownHeading.spec.weight)
        }
        return string
    }
}

/// A card's field (Find or add a tag, the date, a link): a row's height and
/// pill on the recessed fill. Its placeholder sets its width, so a card
/// that fits its content is as wide as the placeholder asks.
struct AtticDropdownField: View {
    @Binding var text: String
    let placeholder: String
    /// A leading glyph (the tag field's magnifier), at the leading edge as
    /// in every Attic search field and NSSearchField (U-13): in the rows'
    /// dot column, so what is typed starts where the tag names do.
    var systemName: String?
    var focus: AtticDropdownFieldFocus
    /// VoiceOver's name for the field (the placeholder by default) and
    /// the UI tests' identifier.
    var label: String?
    var identifier: String?
    var onSubmit: () -> Void = {}

    @Environment(\.atticDesign) private var design

    /// A field alone in its card.
    init(text: Binding<String>, placeholder: String, systemName: String? = nil, focus: FocusState<Bool>.Binding,
         label: String? = nil, identifier: String? = nil, onSubmit: @escaping () -> Void = {}) {
        self.init(text: text, placeholder: placeholder, systemName: systemName, focus: .flag(focus),
                  label: label, identifier: identifier, onSubmit: onSubmit)
    }

    /// A card's field beside its list (`AtticDropdownFocusTarget.field`).
    init(text: Binding<String>, placeholder: String, systemName: String? = nil,
         focus: FocusState<AtticDropdownFocusTarget?>.Binding,
         label: String? = nil, identifier: String? = nil, onSubmit: @escaping () -> Void = {}) {
        self.init(text: text, placeholder: placeholder, systemName: systemName, focus: .target(focus),
                  label: label, identifier: identifier, onSubmit: onSubmit)
    }

    private init(text: Binding<String>, placeholder: String, systemName: String?, focus: AtticDropdownFieldFocus,
                 label: String?, identifier: String?, onSubmit: @escaping () -> Void) {
        _text = text
        self.placeholder = placeholder
        self.systemName = systemName
        self.focus = focus
        self.label = label
        self.identifier = identifier
        self.onSubmit = onSubmit
    }

    var body: some View {
        let m = AtticDropdownMetrics.self
        let font = AtticTextStyle.dropdownRow.font
        HStack(spacing: 0) {
            if let systemName {
                AtticIcon(systemName: systemName, size: AtticSmallControlMetrics.iconSize, ink: .helper)
                    .frame(width: m.dotSlot)
                    .padding(.trailing, m.columnGap)
                    .accessibilityHidden(true)
            }
            ZStack(alignment: .leading) {
                Text(verbatim: placeholder).font(font).lineLimit(1).fixedSize().hidden()
                    .accessibilityHidden(true)
                TextField("", text: $text, prompt: Text(verbatim: placeholder).foregroundStyle(design.tokens.color(.helper)))
                    .textFieldStyle(.plain)
                    .font(font)
                    .modifier(AtticDropdownFieldFocusModifier(focus: focus))
                    .onSubmit(onSubmit)
                    .accessibilityLabel(label ?? placeholder)
                    .accessibilityIdentifier(identifier ?? "")
            }
        }
        .padding(.horizontal, m.rowPadding)
        .frame(height: m.fieldHeight)
        .background(RoundedRectangle(cornerRadius: m.highlightRadius, style: .continuous).fill(design.tokens.recessed.color))
    }
}

/// The focus a card's field takes: its own, or the field half of a card's
/// one field-and-list focus.
enum AtticDropdownFieldFocus {
    case flag(FocusState<Bool>.Binding)
    case target(FocusState<AtticDropdownFocusTarget?>.Binding)
}

private struct AtticDropdownFieldFocusModifier: ViewModifier {
    let focus: AtticDropdownFieldFocus

    func body(content: Content) -> some View {
        switch focus {
        case let .flag(binding): content.focused(binding)
        case let .target(binding): content.focused(binding, equals: .field)
        }
    }
}

// MARK: - Layout

/// The width rule (p2-23) and where a card opens.
enum AtticDropdownLayout {
    enum Side: Equatable, Sendable { case below, above }

    /// A card's width: its content's, never under 144 pt, never wider than
    /// `available` (the panel less its 12 pt margins).
    static func width(ideal: CGFloat, available: CGFloat) -> CGFloat {
        min(max(ideal.rounded(.up), AtticDropdownMetrics.minWidth), max(0, available.rounded(.down)))
    }

    /// The content width of a list of icon-and-name rows (the `/` list),
    /// with the typed `match` emboldened in each name; the card adds its
    /// inset.
    static func listWidth(titles: [String], match: String? = nil) -> CGFloat {
        let m = AtticDropdownMetrics.self
        let regular = AtticTextStyle.dropdownRow
        let bold = AtticTextStyle.dropdownHeading
        let widest = titles.map { title -> CGFloat in
            var width = regular.measuredWidth(title)
            if let match, !match.isEmpty,
               let range = title.range(of: match, options: [.caseInsensitive, .diacriticInsensitive]) {
                let part = String(title[range])
                width += max(0, bold.measuredWidth(part) - regular.measuredWidth(part))
            }
            return width
        }.max() ?? 0
        return m.inset * 2 + m.rowPadding * 2 + m.iconSlot + m.columnGap + widest
    }

    /// Where a card of `size` opens, in top-down coordinates (y grows
    /// down): its left edge on the anchor's (the caret's column, a strip
    /// button), moved left only as far as `bounds` (the panel less its
    /// margin) needs; `prefer`'s side when it fits there, else the other
    /// side, else the roomier one, kept inside `bounds`.
    static func frame(size: CGSize, anchor: CGRect, bounds: CGRect, prefer: Side,
                      gap: CGFloat = AtticDropdownMetrics.anchorGap) -> (frame: CGRect, side: Side) {
        let width = min(size.width, bounds.width)
        let x = max(bounds.minX, min(anchor.minX, bounds.maxX - width))
        let belowY = max(bounds.minY, min(anchor.maxY + gap, bounds.maxY))
        let aboveEnd = max(bounds.minY, min(anchor.minY - gap, bounds.maxY))
        let below = max(0, bounds.maxY - belowY)
        let above = max(0, aboveEnd - bounds.minY)
        let side: Side
        if prefer == .below && size.height <= below { side = .below }
        else if prefer == .above && size.height <= above { side = .above }
        else if size.height <= above { side = .above }
        else if size.height <= below { side = .below }
        else { side = above > below ? .above : .below }
        let height = min(size.height, side == .below ? below : above)
        let y = side == .below ? belowY : aboveEnd - height
        return (CGRect(x: x, y: y, width: width, height: height), side)
    }

    /// `rect` in `view` turned top-down (and back: the flip is its own
    /// inverse).
    static func topDown(_ rect: CGRect, in view: NSView) -> CGRect {
        view.isFlipped ? rect : CGRect(x: rect.minX, y: view.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Where a card sits.
    struct Placement: Equatable {
        /// The card, top-down in its overlay.
        var frame: CGRect
        var side: Side
        /// The card's height when its side can't hold all of it (it
        /// scrolls); nil when it fits.
        var heightLimit: CGFloat?
        /// The width rule's width.
        var width: CGFloat { frame.width }
    }

    /// The one placement every card uses: the width rule from its
    /// content's `idealWidth`, then its side. A card opens on `prefer`'s
    /// side when it fits there. Once open (`current`, its side so far) it
    /// keeps that side, and flips only when the side can't hold it (a
    /// filter, a calendar month, a scroll).
    static func place(idealWidth: CGFloat, height: CGFloat, anchor: CGRect, bounds: CGRect,
                      prefer: Side, current: Side? = nil) -> Placement {
        let width = width(ideal: idealWidth, available: bounds.width)
        let placed = frame(size: CGSize(width: width, height: height), anchor: anchor, bounds: bounds, prefer: current ?? prefer)
        return Placement(frame: placed.frame, side: placed.side,
                         heightLimit: placed.frame.height < height ? placed.frame.height : nil)
    }
}

/// Where a view's cards go: the panel's overlay layer (above the page,
/// moving with the panel, hit-tested first) and the panel less its 12 pt
/// margin, top-down in that layer. Outside a panel (tests, capture scenes):
/// the window's content view, bounded by `bounding`'s visible rectangle.
@MainActor
struct AtticDropdownSpace {
    let parent: NSView
    /// Where cards may go, top-down in `parent`.
    let bounds: CGRect

    init?(around view: NSView, bounding: NSView? = nil) {
        let margin = AtticDropdownMetrics.panelMargin
        var candidate = view.superview
        while let current = candidate {
            if let container = current as? AtticPanelContentContainer {
                parent = container.overlayLayer
                bounds = Self.visibleBounds(AtticDropdownLayout.topDown(container.hostingView.frame, in: parent).insetBy(dx: margin, dy: margin), parent: parent)
                return
            }
            candidate = current.superview
        }
        guard let content = view.window?.contentView, let commonParent = content.superview else { return nil }
        // Standalone SwiftUI pages use NSHostingView as the window's content
        // view. An overlay must be its sibling: inserting another host under
        // it is unsupported and emits a SwiftUI runtime issue (whose XCTest
        // symbolication can stall a keystroke for seconds).
        // Keep placement bounded by the content, not the window's chrome.
        parent = commonParent
        let visible = bounding.map { commonParent.convert($0.visibleRect, from: $0) }
            ?? commonParent.convert(content.bounds, from: content)
        bounds = Self.visibleBounds(AtticDropdownLayout.topDown(visible, in: commonParent).insetBy(dx: margin, dy: margin), parent: commonParent)
    }

    private static func visibleBounds(_ bounds: CGRect, parent: NSView) -> CGRect {
        guard let window = parent.window, let screen = window.screen else { return bounds }
        let screenRect = parent.convert(window.convertFromScreen(screen.visibleFrame), from: nil)
        let visible = bounds.intersection(AtticDropdownLayout.topDown(screenRect, in: parent)
            .insetBy(dx: AtticDropdownMetrics.panelMargin, dy: AtticDropdownMetrics.panelMargin))
        // An unshown/offscreen host has no usable screen intersection;
        // its own bounds still define headless layout.
        return visible.isNull || visible.isEmpty ? bounds : visible
    }

    private init(parent: NSView, bounds: CGRect) {
        self.parent = parent
        self.bounds = bounds
    }

    /// This space ending `clearance` above the bottom of `view`'s visible
    /// part (U-22): a card over a page with floating bottom controls stops
    /// above them, with the panel's margin to spare, instead of covering
    /// them. Unchanged when that would leave no room.
    func clearing(bottom clearance: CGFloat, of view: NSView) -> AtticDropdownSpace {
        guard clearance > 0 else { return self }
        let visible = anchor(view.visibleRect, in: view)
        let maxY = min(bounds.maxY, visible.maxY - clearance)
        guard maxY > bounds.minY + AtticDropdownMetrics.rowHeight * 2 else { return self }
        return AtticDropdownSpace(parent: parent, bounds: CGRect(x: bounds.minX, y: bounds.minY,
                                                                 width: bounds.width, height: maxY - bounds.minY))
    }

    /// `rect` in `view`, top-down in this space.
    func anchor(_ rect: CGRect, in view: NSView) -> CGRect {
        AtticDropdownLayout.topDown(view.convert(rect, to: parent), in: parent)
    }

    /// `AtticDropdownLayout.place` within these bounds.
    func place(idealWidth: CGFloat, height: CGFloat, anchor: CGRect, prefer: AtticDropdownLayout.Side,
               current: AtticDropdownLayout.Side? = nil) -> AtticDropdownLayout.Placement {
        AtticDropdownLayout.place(idealWidth: idealWidth, height: height, anchor: anchor, bounds: bounds,
                                  prefer: prefer, current: current)
    }

    /// Puts a card's host (the card and its shadow room) where `placement`
    /// says, in the overlay (joining it outside AppKit's layout pass:
    /// `AtticOverlayHierarchy`).
    func show(_ host: NSView, at placement: AtticDropdownLayout.Placement, room: CGFloat = AtticDropdownMetrics.shadowRoom) {
        let frame = AtticDropdownLayout.topDown(placement.frame.insetBy(dx: -room, dy: -room), in: parent).integral
        AtticOverlayHierarchy.place(host, in: parent, frame: frame)
    }
}

// MARK: - Overlay hierarchy

/// Overlay views (Notes' bar, `/` list, cards, hint and object ring, the
/// title's tag suggestions, every dropdown card) join, change or leave
/// their parent only outside AppKit's layout pass.
///
/// P1-01 (the freeze: every main-thread sample in `NSHostingView.layout →
/// FocusBridge.updateDefaultKeyViewLoop`) is suspected to come from hosting
/// views joining or leaving the window while it lays out: the text's layout
/// places the overlays, and a SwiftUI update inside the panel's layout can
/// dismantle them. This is a hypothesis until the on-screen check
/// reproduces the freeze or fails to. Inside a layout pass a host already
/// in its parent still moves at once (no one-frame jump); a change of
/// parent waits for the next run-loop turn, coalesced per view (the latest
/// request wins) and skipped when by then there is nothing to change.
@MainActor
enum AtticOverlayHierarchy {
    /// Attic's views in a layout pass (or in a callback that can run in
    /// one, such as a scroll's bounds change) mark it here.
    private(set) static var layoutDepth = 0
    static var isInLayoutPass: Bool { layoutDepth > 0 }

    /// Runs `body` as part of a layout pass.
    static func layoutPass<T>(_ body: () throws -> T) rethrows -> T {
        layoutDepth += 1
        defer { layoutDepth -= 1 }
        return try body()
    }

    private struct Change {
        weak var view: NSView?
        /// Leave the parent (otherwise join `parent`).
        var leaves = false
        weak var parent: NSView?
        var frame: NSRect?
    }
    private static var pending: [ObjectIdentifier: Change] = [:]
    private static var isScheduled = false

    /// Changes waiting for the next turn (tests).
    static var pendingCount: Int { pending.count }

    /// First attachment of a control built during SwiftUI layout. Its
    /// geometry can still be computed while it waits; do not restore the
    /// initial (often zero) frame when it finally joins the text view.
    static func attach(_ view: NSView, to parent: NSView) {
        let id = ObjectIdentifier(view)
        if view.superview === parent { pending[id] = nil; return }
        guard isInLayoutPass else {
            pending[id] = nil
            parent.addSubview(view, positioned: .above, relativeTo: nil)
            return
        }
        pending[id] = Change(view: view, parent: parent)
        schedule()
    }

    /// Puts `view` at `frame` in `parent`, above its siblings.
    static func place(_ view: NSView, in parent: NSView, frame: NSRect) {
        let id = ObjectIdentifier(view)
        if view.superview === parent {
            pending[id] = nil
            if view.frame != frame { view.frame = frame }
            return
        }
        guard isInLayoutPass else {
            pending[id] = nil
            if view.frame != frame { view.frame = frame }
            parent.addSubview(view, positioned: .above, relativeTo: nil)
            return
        }
        // While it waits in another parent it keeps its place on screen.
        if let current = view.superview, current.window != nil, current.window === parent.window {
            let interim = current.convert(frame, from: parent)
            if view.frame != interim { view.frame = interim }
        }
        pending[id] = Change(view: view, parent: parent, frame: frame)
        schedule()
    }

    /// Takes `view` out of its parent. In a layout pass it is hidden now
    /// and leaves on the next turn.
    static func remove(_ view: NSView) {
        let id = ObjectIdentifier(view)
        guard isInLayoutPass else {
            pending[id] = nil
            view.removeFromSuperview()
            return
        }
        guard view.superview != nil || pending[id] != nil else { return }
        if !view.isHidden { view.isHidden = true }
        pending[id] = Change(view: view, leaves: true)
        schedule()
    }

    private static func schedule() {
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async { flush() }
    }

    /// Applies what waited (the next turn; tests may call it).
    static func flush() {
        isScheduled = false
        // AppKit may run a nested loop while laying out. An async callback
        // is not by itself evidence that the outer layout pass has ended.
        guard !isInLayoutPass else { schedule(); return }
        let changes = pending
        pending = [:]
        for change in changes.values {
            guard let view = change.view else { continue }
            if change.leaves {
                if view.superview != nil { view.removeFromSuperview() }
            } else if let parent = change.parent {
                if let frame = change.frame, view.frame != frame { view.frame = frame }
                if view.superview !== parent { parent.addSubview(view, positioned: .above, relativeTo: nil) }
            }
        }
    }
}

// MARK: - Overlay host

/// A SwiftUI host laid over a page in the panel's overlay layer (Notes' bar,
/// `/` list and cards; every dropdown). It never takes the keyboard on a
/// click unless it holds a field (`acceptsKeyboard`), and only its content's
/// rectangle answers the pointer: the shadow room around it is click-through.
final class AtticOverlayHostingView: NSHostingView<AnyView> {
    /// The content's inset from the host's edges (the shadow room).
    var contentInset: CGFloat = AtticNoteFormatMetrics.shadowRoom
    var isInteractive = false
    /// The host takes the keyboard (a card with a field, a picker's keys).
    var acceptsKeyboard = false

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = []
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        AtticPanel.acceptsEveryFirstMouse(in: window) || super.acceptsFirstMouse(for: event)
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Its SwiftUI update (a card's size, a nested card closing) is part of
    /// the layout pass: overlay hierarchy changes from it wait.
    override func layout() {
        #if DEBUG
        if AtticDropdownDiagnostics.enabled { AtticDropdownDiagnostics.layouts += 1 }
        #endif
        AtticOverlayHierarchy.layoutPass { super.layout() }
    }

    override var acceptsFirstResponder: Bool { acceptsKeyboard }

    /// The content's rectangle (the host less its shadow room).
    var contentRect: NSRect { bounds.insetBy(dx: contentInset, dy: contentInset) }

    /// What VoiceOver hears this host as: a dropdown is a menu with its
    /// items (NSHostingView would say "group").
    var menuLabel: String?

    override func accessibilityRole() -> NSAccessibility.Role? {
        menuLabel == nil ? super.accessibilityRole() : .menu
    }

    override func accessibilityLabel() -> String? {
        menuLabel ?? super.accessibilityLabel()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractive, !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard contentRect.contains(local) else { return nil }
        return super.hitTest(point)
    }
}

// MARK: - Presenting

/// The open card's motion and size, which only the card's own host reads.
@MainActor
final class AtticDropdownStageModel: ObservableObject {
    @Published var shown = false
    /// Uncovered (the reveal ran): set as it opens, kept while it fades out.
    @Published var revealed = false
    @Published var side: AtticDropdownLayout.Side = .below
    /// The card's width once the width rule capped it (nil: its content's).
    @Published var width: CGFloat?
    @Published var height: CGFloat?
    /// Bumped once the card's host has the keyboard: the content's own
    /// focus (`atticDropdownFocus`) takes it then. 0 until this opening's
    /// host has it (reset as each card opens).
    @Published var focusRequest = 0
}

private struct AtticDropdownFocusRequestKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    /// Changes when a dropdown's host takes the keyboard; nil outside a
    /// presented dropdown.
    var atticDropdownFocusRequest: Int? {
        get { self[AtticDropdownFocusRequestKey.self] }
        set { self[AtticDropdownFocusRequestKey.self] = newValue }
    }
}

extension View {
    /// Focuses `focus` when its dropdown's host takes the keyboard, or as
    /// the view appears outside a presented dropdown.
    ///
    /// In a presented dropdown it never asks as it appears: the presenter
    /// measures the card before its host joins the window, and a focus
    /// asked for then reached SwiftUI's focus bridge with a key-view proxy
    /// outside any window, which AppKit refuses by clearing the window's
    /// first responder ("Setting <SwiftUI.KeyViewProxy> as the first
    /// responder … but it is in a different window"). With accessibility
    /// or Full Keyboard Access on, the card's field then lost the keyboard.
    func atticDropdownFocus(_ focus: FocusState<Bool>.Binding, when enabled: Bool = true) -> some View {
        modifier(AtticDropdownFocusModifier(focus: { if !focus.wrappedValue { focus.wrappedValue = true } }, enabled: enabled))
    }

    /// `atticDropdownFocus` for a card with a field and a list: the field
    /// takes the keyboard.
    func atticDropdownFocus(_ focus: FocusState<AtticDropdownFocusTarget?>.Binding, when enabled: Bool = true) -> some View {
        // Only while nothing in the card has the keyboard: the opening's
        // focus never undoes a move the person already made (Tab).
        modifier(AtticDropdownFocusModifier(focus: { if focus.wrappedValue == nil { focus.wrappedValue = .field } }, enabled: enabled))
    }
}

enum AtticDropdownInitialFocus {
    static func shouldRequest(enabled: Bool, request: Int?) -> Bool {
        enabled && (request == nil || (request ?? 0) > 0)
    }
}

private struct AtticDropdownFocusModifier: ViewModifier {
    let focus: () -> Void
    let enabled: Bool
    @Environment(\.atticDropdownFocusRequest) private var request

    func body(content: Content) -> some View {
        content
            .onAppear { if AtticDropdownInitialFocus.shouldRequest(enabled: enabled, request: request) { focus() } }
            .onChange(of: request) { _, now in if AtticDropdownInitialFocus.shouldRequest(enabled: enabled, request: now) { focus() } }
    }
}

/// A CSS-style cubic Bézier timing curve, solved for y at a given x (time),
/// as WebKit's `UnitBezier` does: Newton's method, then bisection.
struct AtticCubicBezier: Equatable, Sendable {
    let x1: Double, y1: Double, x2: Double, y2: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
    }

    private func sample(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let c = 3 * p1, b = 3 * (p2 - p1) - c, a = 1 - c - b
        return ((a * t + b) * t + c) * t
    }

    private func slope(_ t: Double) -> Double {
        let c = 3 * x1, b = 3 * (x2 - x1) - c, a = 1 - c - b
        return (3 * a * t + 2 * b) * t + c
    }

    /// The curve's progress at `x` (0...1, clamped).
    func y(at x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        var t = x
        for _ in 0..<8 {
            let error = sample(t, x1, x2) - x
            if abs(error) < 1e-6 { return sample(t, y1, y2) }
            let d = slope(t)
            if abs(d) < 1e-6 { break }
            t -= error / d
        }
        var low = 0.0, high = 1.0
        t = x
        for _ in 0..<40 {
            let value = sample(t, x1, x2)
            if abs(value - x) < 1e-6 { break }
            if value < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return sample(t, y1, y2)
    }
}

/// How every Attic-drawn dropdown, menu and pop-over opens and closes: the
/// owner's "unfold" (O14-02, owner 2026-10-14; it replaces N-4 B's mask
/// reveal and option A's grow). The card unfolds from the edge by its
/// anchor rather than zooming: its height grows from one row's (28 pt) to
/// its own, it fades in, grows from 0.98 at that edge's leading corner and
/// drops 4 pt into place; its shadow grows with it. Its contents follow
/// 30 ms later, from a 5 pt blur to sharp over 130 ms. 180 ms in all on the
/// fast-out curve (0.16, 1, 0.3, 1). Closing runs the same path back, faster
/// (120 ms): towards one row's height, to clear, 3 pt back towards the
/// anchor. Reduced: a short fade only.
///
/// Cheap by construction: the card is laid out once at its full size. Only
/// the effect's own modifiers (opacity, scale, offset) and two leaves (the
/// surface's shape and shadow, `AtticDropdownSurface`; the contents' mask
/// and blur, `AtticUnfoldContent`) change per frame; the rows never re-run.
enum AtticDropdownReveal {
    static let openDuration: Double = 0.18
    static let closeDuration: Double = 0.12
    /// The contents start this long after the card…
    static let contentDelay: Double = 0.03
    /// …and sharpen over this long.
    static let contentDuration: Double = 0.13
    /// The height a card unfolds from (one row's) and closes back towards.
    static let startHeight: CGFloat = 28
    static let startScale: CGFloat = 0.98
    /// Towards the anchor as it opens (the drop) and as it closes.
    static let openTravel: CGFloat = 4
    static let closeTravel: CGFloat = 3
    static let contentBlur: CGFloat = 5
    /// The card is wholly opaque by this point of its unfold (U-41): its
    /// face hides the rows under it from its first frames while its height
    /// keeps growing and its contents sharpen, never a see-through card
    /// over the list (and the same on the way back, until the last of it).
    static let opaqueBy: CGFloat = 0.3

    /// The card's opacity at `progress` (0...1 of the curve).
    static func opacity(progress: CGFloat) -> CGFloat { min(1, max(0, progress) / opaqueBy) }
    /// The owner's fast-out curve.
    static let curve = AtticCubicBezier(0.16, 1, 0.3, 1)

    /// The effect's clock runs linearly; `frame` applies the curve, so the
    /// card and its contents can keep their own timings on one clock.
    static var openAnimation: Animation { .linear(duration: openDuration) }
    /// The card's opacity on its own, 0 → 1 on the curve: what an inserted
    /// card fades in by (`AtticUnfoldPresence`).
    static var openOpacityAnimation: Animation { .timingCurve(0.16, 1, 0.3, 1, duration: openDuration) }
    static var closeAnimation: Animation { .linear(duration: closeDuration) }
    /// The motion's opening animation (callers that animate the presenting
    /// state alongside it).
    static var revealAnimation: Animation { openAnimation }
    /// Reduced: a short fade (F/E), both ways.
    static var fadeAnimation: Animation { AtticMotionScale.reducedFade }

    /// One moment of the motion. `travel` is towards the anchor (up for a
    /// card below it).
    struct Frame: Equatable {
        var reveal: CGFloat
        var opacity: CGFloat
        var scale: CGFloat
        var travel: CGFloat
        var contentBlur: CGFloat
        var shadow: CGFloat

        static let rest = Frame(reveal: 1, opacity: 1, scale: 1, travel: 0, contentBlur: 0, shadow: 1)
    }

    /// The frame at `time` (0...1 of its leg's duration): opening from 0,
    /// or closing from 0 (open) to 1 (gone).
    static func frame(time: CGFloat, closing: Bool) -> Frame {
        let t = Double(max(0, min(1, time)))
        if closing ? t <= 0 : t >= 1 { return .rest }
        if closing {
            // V-11: the card leaves as one piece, the native way: whole,
            // fading with its shadow, 0.98 and 3 pt towards its anchor. It
            // never folds back to its first row (the tag card's "Find or
            // add a tag" field stood alone for frames), as a removed card
            // never has (`AtticUnfoldPresence`).
            let e = CGFloat(curve.y(at: t))
            return Frame(reveal: 1, opacity: 1 - e, scale: 1 - (1 - startScale) * e, travel: closeTravel * e,
                         contentBlur: 0, shadow: 1 - e)
        }
        let e = CGFloat(curve.y(at: t))
        let contentTime = (t * openDuration - contentDelay) / contentDuration
        let c = CGFloat(curve.y(at: contentTime))
        return Frame(reveal: e, opacity: opacity(progress: e), scale: startScale + (1 - startScale) * e, travel: openTravel * (1 - e),
                     contentBlur: contentBlur * (1 - c), shadow: e)
    }

    #if DEBUG
    /// Capture seam (`ATTIC_UI_TEST_UNFOLD_FREEZE=0.25`, UI testing in a
    /// preview identity only): openings stop at that point of their clock,
    /// for stills of the motion mid-way.
    nonisolated static let freeze: CGFloat? = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["ATTIC_UI_TESTING"] == "1", AtticPreviewOverrides.isPreviewIdentity(Bundle.main.bundleIdentifier),
              let raw = environment["ATTIC_UI_TEST_UNFOLD_FREEZE"], let value = Double(raw), (0...1).contains(value) else { return nil }
        return CGFloat(value)
    }()
    #endif
}

/// Shows `content` for `value` with the unfold, for cards that come and go
/// with state (the `/` list, Notes' date and link cards, a Done task's
/// details).
///
/// Opening, each card drives `AtticUnfoldEffect` from its own state
/// (`AtticUnfolding`): a SwiftUI transition does not carry the motion's
/// state to the card as a whole, so the rows in its scroll view would not
/// be cut or blurred. Its opacity is the insertion transition's, on the
/// same curve, which also leaves its first drawing to the frames that
/// animate it (the `/` list's open-cost gate). Closing is the removal
/// transition: the same path back in 120 ms by opacity, scale and travel
/// (a removed card's rows cannot be cut, so it does not fold its height).
/// Reduced: a fade.
struct AtticUnfoldPresence<Value: Equatable, Content: View>: View {
    let value: Value?
    var fromTop = true
    @ViewBuilder let content: (Value) -> Content

    @Environment(\.atticDesign) private var design

    var body: some View {
        let reduced = design.reduceMotion
        ZStack {
            if let value {
                AtticUnfolding(fromTop: fromTop, reduced: reduced) { content(value) }
                    .transition(reduced ? .opacity.animation(AtticDropdownReveal.fadeAnimation) : AtticDropdownReveal.presence(fromTop: fromTop))
            }
        }
        // The insertion and removal run in an animated transaction, as
        // N-4's did: on macOS 26 a transition's own animation alone left the
        // insertion unanimated there, so the inserting turn drew the whole
        // card (CI: the / list's open at 0.95-1.18 of the replaced list's).
        .animation(value != nil ? AtticDropdownReveal.openOpacityAnimation : AtticDropdownReveal.closeAnimation, value: value != nil)
    }
}

extension AtticDropdownReveal {
    /// `AtticUnfoldPresence`'s insertion and removal.
    static func presence(fromTop: Bool) -> AnyTransition {
        let close = AnyTransition.modifier(active: AtticUnfoldEffect(clock: 0, closing: true, fromTop: fromTop, carriesState: false),
                                           identity: AtticUnfoldEffect(clock: 1, closing: true, fromTop: fromTop, carriesState: false))
        let insertion = AnyTransition.modifier(active: AtticUnfoldInsertion(shown: 0), identity: AtticUnfoldInsertion(shown: 1))
        return .asymmetric(insertion: insertion.animation(openOpacityAnimation), removal: close.animation(closeAnimation))
    }
}

/// An inserted card's first frame draws nothing: it is cut to an empty
/// rectangle until its insertion has begun to animate (N-4's reveal did the
/// same with its mask). Clear anyway at that moment (its opacity is 0), so
/// nothing changes on screen; on a renderer that still draws clear content
/// (CI's), it keeps the inserting turn cheap.
struct AtticUnfoldInsertion: ViewModifier, Animatable {
    var shown: CGFloat

    var animatableData: CGFloat {
        get { shown }
        set { shown = newValue }
    }

    func body(content: Content) -> some View {
        // Its fade is the unfold's: opaque early (U-41).
        content.mask { AtticInsertionCut(open: shown > 0) }
            .opacity(AtticDropdownReveal.opacity(progress: shown))
    }
}

private struct AtticInsertionCut: Shape {
    let open: Bool
    func path(in rect: CGRect) -> Path { Path(open ? rect.insetBy(dx: -AtticDropdownMetrics.shadowRoom, dy: -AtticDropdownMetrics.shadowRoom) : .zero) }
}

extension AtticDropdownReveal {
    /// The unfold by opacity, scale and travel alone, both ways, for a
    /// pop-over that is only a transition (a Done task's details).
    static func transformsOnly(fromTop: Bool) -> AnyTransition {
        let open = AnyTransition.modifier(active: AtticUnfoldEffect(clock: 0, closing: false, fromTop: fromTop, carriesState: false),
                                          identity: AtticUnfoldEffect(clock: 1, closing: false, fromTop: fromTop, carriesState: false))
        let close = AnyTransition.modifier(active: AtticUnfoldEffect(clock: 0, closing: true, fromTop: fromTop, carriesState: false),
                                           identity: AtticUnfoldEffect(clock: 1, closing: true, fromTop: fromTop, carriesState: false))
        return .asymmetric(insertion: open.animation(openAnimation), removal: close.animation(closeAnimation))
    }
}

/// One opening of an `AtticUnfoldPresence` card: it unfolds from shut as
/// it appears.
struct AtticUnfolding<Content: View>: View {
    let fromTop: Bool
    let reduced: Bool
    @ViewBuilder let content: Content
    @State private var clock: CGFloat = 0

    var body: some View {
        content
            // Its opacity is the insertion's (the same curve), so the card is
            // clear in the turn that inserts it, as N-4's was: that turn draws
            // nothing (the `/` list's open-cost gate), and VoiceOver finds the
            // card at once.
            .modifier(AtticUnfoldEffect(clock: reduced ? 1 : clock, closing: false, fromTop: fromTop, appliesOpacity: false))
            .onAppear {
                guard !reduced else { return }
                DispatchQueue.main.async {
                    withAnimation(AtticDropdownReveal.openAnimation) { clock = 1 }
                    PerformanceSignposts.watchFrames("CardUnfold", seconds: 0.3)
                }
            }
    }
}

/// The motion's state for the card's two leaves (`AtticDropdownSurface`,
/// `AtticUnfoldContent`); nil outside a moving card (at rest).
struct AtticUnfoldState: Equatable {
    var reveal: CGFloat
    var fromTop: Bool
    var contentBlur: CGFloat
    var shadow: CGFloat
}

extension EnvironmentValues {
    @Entry var atticUnfold: AtticUnfoldState? = nil
}

/// The unfold on a card, at `clock`: 1 is open; 0 is shut as it starts
/// to open, or gone as it finishes closing (the closing leg runs 1 → 0).
/// The clock is linear; `AtticDropdownReveal.frame` applies the curve.
struct AtticUnfoldEffect: ViewModifier, Animatable {
    var clock: CGFloat
    let closing: Bool
    let fromTop: Bool
    /// Reduce Motion: the clock is a fade alone.
    var reduced = false
    /// It tells the card's leaves (the surface, the rows' cut and blur) the
    /// motion; a removal transition's cannot reach the rows, so it doesn't.
    var carriesState = true
    /// The card's opacity is the effect's (not an insertion transition's).
    var appliesOpacity = true

    var animatableData: CGFloat {
        get { clock }
        set { clock = newValue }
    }

    func body(content: Content) -> some View {
        var time = reduced ? 1 : (closing ? 1 - clock : clock)
        #if DEBUG
        if !closing, !reduced, let freeze = AtticDropdownReveal.freeze { time = min(time, freeze) }
        #endif
        let f = AtticDropdownReveal.frame(time: time, closing: closing)
        // At rest, and while wholly clear (the opening's first frame, laid
        // out in the same turn as the open), the card needs no cut or blur.
        let state = !carriesState || f == .rest || f.opacity <= 0 ? nil : AtticUnfoldState(reveal: f.reveal, fromTop: fromTop, contentBlur: f.contentBlur, shadow: f.shadow)
        // An asymmetric transition stacks its two legs' effects; the one at
        // rest must not clear the moving one's state.
        return content
            .transformEnvironment(\.atticUnfold) { if let state { $0 = state } }
            .scaleEffect(f.scale, anchor: fromTop ? .topLeading : .bottomLeading)
            .offset(y: fromTop ? -f.travel : f.travel)
            .opacity(reduced ? clock : (appliesOpacity ? f.opacity : 1))
    }
}

/// A card's outline while it unfolds: its rounded rectangle, cut to the
/// revealed height from its anchor's edge (the whole card at rest).
struct AtticUnfoldShape: InsettableShape, Equatable {
    let cornerRadius: CGFloat
    var reveal: CGFloat = 1
    var fromTop = true
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> AtticUnfoldShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    static func height(reveal: CGFloat, full: CGFloat) -> CGFloat {
        let start = min(full, AtticDropdownReveal.startHeight)
        return min(full, start + (full - start) * max(0, min(1, reveal)))
    }

    func path(in rect: CGRect) -> Path {
        let height = Self.height(reveal: reveal, full: rect.height)
        let shown = CGRect(x: rect.minX, y: fromTop ? rect.minY : rect.maxY - height, width: rect.width, height: height)
            .insetBy(dx: insetAmount, dy: insetAmount)
        let radius = max(0, min(cornerRadius, height / 2) - insetAmount)
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: shown)
    }
}

extension EnvironmentValues {
    /// The corner radius of the card whose contents these are.
    @Entry var atticUnfoldCornerRadius: CGFloat = AtticDropdownMetrics.cornerRadius
    /// An enclosing `AtticUnfoldContent` already cuts and blurs this content.
    @Entry var atticUnfoldTreated = false
}

/// A card that unfolds: its coordinate space and corners, so its contents
/// (which can sit in their own scroll views, where the card's own mask and
/// blur never reach) are cut to its revealed outline (`AtticUnfoldContent`).
/// Nothing here changes per frame.
struct AtticUnfoldCard: ViewModifier {
    static let space = "attic.unfold.card"
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .environment(\.atticUnfoldCornerRadius, cornerRadius)
            .coordinateSpace(.named(Self.space))
    }
}

/// A card's contents as it unfolds: cut to the card's revealed outline
/// (found from the card's coordinate space, so no size is stored) and from
/// a blur to sharp just after it. On the outermost contents, and again
/// inside any scroll view (whose rows the outer cut cannot reach). At rest
/// it cuts nothing and reads no geometry.
struct AtticUnfoldContent: ViewModifier {
    /// The content is a scroll view's own.
    var scrolls = false
    @Environment(\.atticUnfold) private var unfold
    @Environment(\.atticUnfoldCornerRadius) private var cornerRadius
    @Environment(\.atticUnfoldTreated) private var treated

    func body(content: Content) -> some View {
        let active = (scrolls || !treated) ? unfold : nil
        content
            .mask {
                if let active {
                    GeometryReader { proxy in
                        if let card = proxy.bounds(of: .named(AtticUnfoldCard.space)) {
                            AtticUnfoldShape(cornerRadius: cornerRadius, reveal: active.reveal, fromTop: active.fromTop).path(in: card)
                        } else {
                            Rectangle()
                        }
                    }
                } else {
                    Rectangle()
                }
            }
            .blur(radius: active?.contentBlur ?? 0)
            .environment(\.atticUnfoldTreated, true)
    }
}

/// The card on screen, with the dropdowns' motion (`AtticDropdownReveal`):
/// it unfolds from the edge by its anchor as it opens and fades away whole
/// as it closes (V-11); Reduced, it fades. Only this host moves.
struct AtticDropdownStage: View {
    @ObservedObject var model: AtticDropdownStageModel
    let content: AnyView
    var contentHasCard = false

    @Environment(\.atticDesign) private var design

    var body: some View {
        let reduce = design.reduceMotion
        // A card below its anchor unfolds down from its top edge; above
        // it, up from its bottom edge.
        let fromTop = model.side == .below
        // Opening runs the clock 0 → 1; closing (it was shown) runs it
        // back, on the closing leg's path and timing.
        let closing = !reduce && model.revealed && !model.shown
        Group {
            if contentHasCard { content }
            else { AtticDropdownCard(width: model.width) { content } }
        }
            .environment(\.atticDropdownHeight, model.height)
            .environment(\.atticDropdownWidth, model.width)
            .animation(reduce ? nil : (closing ? AtticDropdownReveal.closeAnimation : AtticDropdownReveal.openAnimation)) {
                $0.modifier(AtticUnfoldEffect(clock: reduce || model.shown ? 1 : 0, closing: closing, fromTop: fromTop))
            }
            // Reduced: the fade alone.
            .animation(model.shown ? AtticDropdownReveal.fadeAnimation : AtticMotionScale.exit) {
                $0.opacity(!reduce || model.shown ? 1 : 0)
            }
            .environment(\.atticDropdownFocusRequest, model.focusRequest)
            .padding(AtticDropdownMetrics.shadowRoom)
    }
}

/// Shows one dropdown card in the panel's overlay layer (above the page,
/// moving with the panel, hit-tested first), placed by the width rule from
/// its anchor. The page behind is never re-rendered: the card has its own
/// host, and only the state that opened it changes. While it is open its
/// keys are its own (`AtticTextInput.isPopoverOpen`); Esc, a click outside
/// or the panel losing the keyboard closes it, and the keyboard goes back
/// where it was.
@MainActor
final class AtticDropdownPresenter {
    /// How many dropdowns are open (the row and page keys stand aside).
    private(set) static var openCount = 0
    static var isAnyOpen: Bool { openCount > 0 }

    let stage = AtticDropdownStageModel()
    private(set) var host: AtticOverlayHostingView?
    private(set) var isOpen = false
    /// Asked to open (the binding is true): the next turn presents.
    var wantsOpen = false
    /// Sets the presenting binding to false.
    var onDismiss: (() -> Void)?
    var prefer: AtticDropdownLayout.Side = .below
    var takesKeyboard = true
    var contentHasCard = false
    var contentHeight: CGFloat?
    /// The content's known width (a card's, before the width rule), for
    /// content whose rows change while open (typing suggestions): the card
    /// follows it rather than keeping its opening width.
    var contentWidth: CGFloat?
    /// The open card's width (the width rule's, set as it opens) and
    /// natural height (its content's, which can change while open).
    private var openWidth: CGFloat = 0
    private var openIdealWidth: CGFloat = 0
    private var naturalHeight: CGFloat = 0
    private var contentKeyHandler: ((NSEvent) -> Bool)?
    var label = ""
    var design = AtticDesignContext()
    var tagColouring = AtticTagColouring()
    var content = AnyView(EmptyView())

    private weak var anchor: NSView?
    private weak var previousResponder: NSResponder?
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    private var geometryObservers: [NSObjectProtocol] = []
    private var placementScheduled = false
    private var removal: DispatchWorkItem?
    private var updateScheduled = false
    private var pendingClose: DispatchWorkItem?

    init() {}

    private var root: AnyView {
        AnyView(AtticDropdownStage(model: stage, content: content, contentHasCard: contentHasCard)
            .environment(\.atticDropdownContentHeightChanged, contentHeight == nil ? { [weak self] height in
                self?.resize(height: height)
            } : nil)
            .environment(\.atticDropdownContentWidthChanged, contentWidth == nil ? { [weak self] width in
                self?.grow(toWidth: width)
            } : nil)
            .environment(\.atticDropdownRegisterKeys, { [weak self] handler in self?.contentKeyHandler = handler })
            .environment(\.atticTagColouring, tagColouring)
            .atticDesign(design))
    }

    /// Opens the card from `anchor`.
    func present(from anchor: NSView) {
        guard !isOpen, let window = anchor.window, let space = AtticDropdownSpace(around: anchor) else { return }
        removal?.cancel()
        removal = nil
        if let host { AtticOverlayHierarchy.remove(host) }
        self.anchor = anchor
        let room = AtticDropdownMetrics.shadowRoom
        // This opening's host has not taken the keyboard yet: an earlier
        // opening's request must not focus the new card early (R3-01).
        stage.focusRequest = 0
        stage.shown = false
        stage.revealed = false
        stage.width = nil
        stage.height = nil
        stage.side = prefer
        let host = AtticOverlayHostingView(rootView: root)
        host.contentInset = room
        host.acceptsKeyboard = takesKeyboard
        host.isInteractive = true
        // Measure the opening width once. Natural content height is observed
        // inside the card, including when its viewport is constrained.
        let fitting = host.fittingSize
        let ideal = contentWidth ?? (fitting.width - room * 2)
        let height = contentHeight ?? max(0, fitting.height - room * 2)
        let placed = space.place(idealWidth: ideal, height: height, anchor: space.anchor(anchor.bounds, in: anchor), prefer: prefer)
        if contentHasCard || placed.width != ideal.rounded(.up) { stage.width = placed.width }
        openWidth = placed.width
        openIdealWidth = ideal
        naturalHeight = height
        stage.side = placed.side
        stage.height = placed.heightLimit
        host.menuLabel = label
        space.show(host, at: placed)
        self.host = host
        isOpen = true
        if takesKeyboard { Self.openCount += 1 }
        previousResponder = Self.owner(of: window.firstResponder)
        install(in: window)
        // The host takes the keyboard now, while nothing can have reached
        // the card: deferred to the next turn, a cold first opening ran it
        // after the first Tab, and it put the keyboard back in the field
        // (H5-04, CI). A host still waiting to join the window (a layout
        // pass) takes it on the next turn.
        if takesKeyboard, host.window != nil { takeKeyboard() }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isOpen else { return }
            if self.takesKeyboard, self.stage.focusRequest == 0 { self.takeKeyboard() }
            #if DEBUG
            if AtticDropdownDiagnostics.enabled { AtticDropdownDiagnostics.reveals += 1 }
            #endif
            self.stage.shown = true
            self.stage.revealed = true
            PerformanceSignposts.watchFrames("DropdownUnfold", seconds: 0.3)
        }
    }

    /// Opens it if it is still asked for and the anchor is in a window
    /// (otherwise the anchor calls again when it joins one).
    func presentIfWanted(from anchor: NSView) {
        guard wantsOpen, !isOpen, anchor.window != nil else { return }
        wantsOpen = false
        present(from: anchor)
    }

    /// New content while open (the page's state changed: a tick, a failure line).
    func update() {
        host?.rootView = root
        // Typing suggestions can gain or lose rows while open. Their known
        // height (and width) avoid another content-measuring pass on every
        // keystroke.
        if let height = contentHeight { resize(height: height, width: contentWidth) }
    }

    /// Representable callbacks run inside SwiftUI's update. Resizing the
    /// card publishes stage geometry, so coalesce it onto the next turn.
    func updateAfterViewUpdate() {
        // A true binding can arrive again before the false binding's close.
        // Keep this host and its monitors alive for the newer presentation.
        pendingClose?.cancel()
        pendingClose = nil
        host?.isInteractive = true
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            guard self.isOpen, self.pendingClose == nil else { return }
            if AtticOverlayHierarchy.isInLayoutPass { self.updateAfterViewUpdate(); return }
            self.update()
        }
    }

    /// Dismantling an anchor also runs inside SwiftUI's update. Stop native
    /// interaction now; publish the leave animation after that update ends.
    func closeAfterViewUpdate() {
        wantsOpen = false
        host?.isInteractive = false
        guard pendingClose == nil else { return }
        let work = DispatchWorkItem { [self] in
            pendingClose = nil
            if AtticOverlayHierarchy.isInLayoutPass { closeAfterViewUpdate(); return }
            close(restoreFocus: true)
        }
        pendingClose = work
        DispatchQueue.main.async(execute: work)
    }

    /// The content's natural height changed while open (a filter, a
    /// calendar month, a failure line): the card keeps its side unless that
    /// side can't hold it.
    private func resize(height: CGFloat, width: CGFloat? = nil) {
        let widthChanged = width.map { abs($0 - openIdealWidth) > 0.5 } ?? false
        guard isOpen, height.isFinite, height > 0, abs(height - naturalHeight) > 0.5 || widthChanged,
              let host, let anchor, let space = AtticDropdownSpace(around: anchor) else { return }
        naturalHeight = height
        let placed = space.place(idealWidth: width ?? openWidth, height: height, anchor: space.anchor(anchor.bounds, in: anchor),
                                 prefer: prefer, current: stage.side)
        if let width {
            openIdealWidth = width
            if placed.width != openWidth {
                openWidth = placed.width
                stage.width = placed.width
            }
        }
        if stage.side != placed.side { stage.side = placed.side }
        if stage.height != placed.heightLimit { stage.height = placed.heightLimit }
        space.show(host, at: placed)
    }

    /// A measured card's content needs more width than the card opened
    /// with (a longer row appeared while filtering): the card grows, within
    /// the width rule, keeping its side. It never narrows while open, so
    /// filtering never makes it jump in.
    func grow(toWidth width: CGFloat) {
        guard isOpen, width.isFinite, width > openIdealWidth + 0.5,
              let host, let anchor, let space = AtticDropdownSpace(around: anchor) else { return }
        openIdealWidth = width
        let placed = space.place(idealWidth: width, height: naturalHeight, anchor: space.anchor(anchor.bounds, in: anchor),
                                 prefer: prefer, current: stage.side)
        guard placed.width > openWidth + 0.5 else { return }
        openWidth = placed.width
        stage.width = placed.width
        if stage.side != placed.side { stage.side = placed.side }
        if stage.height != placed.heightLimit { stage.height = placed.heightLimit }
        space.show(host, at: placed)
    }

    /// The open card's width (tests).
    var cardWidth: CGFloat { openWidth }

    /// Closes the card (the binding went false, or the anchor went away).
    func close(restoreFocus: Bool, immediately: Bool = false) {
        pendingClose?.cancel()
        pendingClose = nil
        wantsOpen = false
        guard isOpen, let host else { return }
        isOpen = false
        if takesKeyboard { Self.openCount = max(0, Self.openCount - 1) }
        uninstall()
        contentKeyHandler = nil
        host.isInteractive = false
        host.setAccessibilityElement(false)
        let window = host.window
        let responderInside = (window?.firstResponder as? NSView).map { $0 === host || $0.isDescendant(of: host) } ?? false
        if restoreFocus, responderInside, let window {
            if let previous = previousResponder as? NSView, previous.window === window {
                window.makeFirstResponder(previous)
            } else {
                window.makeFirstResponder(nil)
            }
        } else if responderInside {
            window?.makeFirstResponder(nil)
        }
        previousResponder = nil
        if immediately {
            AtticOverlayHierarchy.remove(host)
            self.host = nil
            return
        }
        stage.shown = false
        let work = DispatchWorkItem { [weak self, weak host] in
            if let host { AtticOverlayHierarchy.remove(host) }
            if let self, self.host === host { self.host = nil }
        }
        removal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AtticDropdownMetrics.leaveCleanup, execute: work)
    }

    /// The person closed it (Esc, a click outside, the panel let go).
    func dismiss() {
        guard isOpen else { return }
        onDismiss?()
        close(restoreFocus: true)
    }

    /// The host takes the keyboard; then the content's own SwiftUI focus
    /// (`atticDropdownFocus`) alone puts it in the card's field or list.
    /// AppKit never focuses a SwiftUI field itself: making the field first
    /// responder here as well gave it two owners, and under Full Keyboard
    /// Access SwiftUI could then think the list had the keyboard while the
    /// field's editor kept it (H5-04).
    private func takeKeyboard() {
        guard let host, let window = host.window else { return }
        host.layoutSubtreeIfNeeded()
        // A card that already has the keyboard keeps it where it is.
        let inside = (window.firstResponder as? NSView).map { $0 === host || $0.isDescendant(of: host) } ?? false
        if !inside { window.makeFirstResponder(host) }
        stage.focusRequest += 1
    }

    /// The view to give the keyboard back to: a field's own view, not the
    /// window's shared field editor, which leaves with the editing.
    static func owner(of responder: NSResponder?) -> NSResponder? {
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSResponder {
            return field
        }
        return responder
    }

    private func install(in window: NSWindow) {
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
        let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleClick(event)
        }
        monitors = [keys, clicks].compactMap { $0 }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } }
        // Content height can stay exactly the same while the panel or its
        // anchor moves. Refitting cannot depend on a new height preference.
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
            geometryObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedulePlacementUpdate() }
            })
        }
        geometryObservers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePlacementUpdate() }
        })
        var ancestor = anchor
        while let view = ancestor {
            view.postsFrameChangedNotifications = true
            view.postsBoundsChangedNotifications = true
            for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                geometryObservers.append(center.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.schedulePlacementUpdate() }
                })
            }
            ancestor = view.superview
        }
    }

    private func schedulePlacementUpdate() {
        guard isOpen, !placementScheduled else { return }
        placementScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.placementScheduled = false
            if AtticOverlayHierarchy.isInLayoutPass { self.schedulePlacementUpdate(); return }
            guard self.isOpen, let host = self.host, let anchor = self.anchor,
                  let space = AtticDropdownSpace(around: anchor) else { return }
            let placed = space.place(idealWidth: self.openIdealWidth, height: self.naturalHeight,
                                     anchor: space.anchor(anchor.bounds, in: anchor), prefer: self.prefer, current: self.stage.side)
            if self.stage.side != placed.side { self.stage.side = placed.side }
            if self.stage.height != placed.heightLimit { self.stage.height = placed.heightLimit }
            if self.openWidth != placed.width { self.openWidth = placed.width; self.stage.width = placed.width }
            space.show(host, at: placed)
        }
    }

    /// Let the active input method cancel composition before dismissing.
    func handleKey(_ event: NSEvent) -> NSEvent? {
        guard isOpen, event.type == .keyDown, event.window === host?.window,
              (event.window?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return event }
        if contentKeyHandler?(event) == true { return nil }
        guard event.keyCode == 53,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
        dismiss()
        return nil
    }

    /// The monitor's real click routing, also exercised off-screen.
    func handleClick(_ event: NSEvent) -> NSEvent? {
        guard isOpen, let host else { return event }
        guard event.window === host.window else {
            dismiss()
            return event
        }
        if host.contentRect.contains(host.convert(event.locationInWindow, from: nil)) { return event }
        let onAnchor = anchor.map { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } ?? false
        dismiss()
        // A toggle button only closes its card. Automatic suggestions have
        // no toggle: clicks in their editor or strip still perform the action.
        return onAnchor && takesKeyboard ? nil : event
    }

    private func uninstall() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        geometryObservers.forEach { NotificationCenter.default.removeObserver($0) }
        geometryObservers = []
    }
}

/// The anchor a dropdown opens from: an empty view behind the control.
struct AtticDropdownAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let prefer: AtticDropdownLayout.Side
    let label: String
    let takesKeyboard: Bool
    let contentHasCard: Bool
    let contentHeight: CGFloat?
    var contentWidth: CGFloat? = nil
    let design: AtticDesignContext
    let content: () -> AnyView

    final class AnchorView: NSView {
        /// Opens a card that was asked for before this view had a window.
        var onWindow: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // After SwiftUI's layout pass, so the anchor has its frame.
            DispatchQueue.main.async { [weak self] in self?.onWindow?() }
        }
    }

    func makeCoordinator() -> AtticDropdownPresenter { AtticDropdownPresenter() }

    func makeNSView(context: Context) -> AnchorView { AnchorView(frame: .zero) }

    func updateNSView(_ view: AnchorView, context: Context) {
        let presenter = context.coordinator
        let binding = $isPresented
        presenter.onDismiss = { if binding.wrappedValue { binding.wrappedValue = false } }
        presenter.prefer = prefer
        presenter.label = label
        presenter.takesKeyboard = takesKeyboard
        presenter.contentHasCard = contentHasCard
        presenter.contentHeight = contentHeight
        presenter.contentWidth = contentWidth
        presenter.design = design
        // The card is hosted apart from the page: it takes the tag colours
        // from where it opens, so a tag's dot is the hue its row shows.
        presenter.tagColouring = context.environment.atticTagColouring
        guard isPresented else {
            if presenter.isOpen || presenter.wantsOpen { presenter.closeAfterViewUpdate() }
            return
        }
        presenter.content = content()
        if presenter.isOpen {
            presenter.updateAfterViewUpdate()
        } else if !presenter.wantsOpen {
            presenter.wantsOpen = true
            view.onWindow = { [weak view, weak presenter] in
                guard let view, let presenter else { return }
                presenter.presentIfWanted(from: view)
            }
            // After this update: the anchor has its frame, and opening
            // changes no state while SwiftUI is updating views.
            DispatchQueue.main.async { [weak view, weak presenter] in
                guard let view, let presenter else { return }
                presenter.presentIfWanted(from: view)
            }
        }
    }

    /// The binding went false (the anchor leaves with it), or the control
    /// itself went away: the card leaves with its motion and the keyboard
    /// goes back (its host removes itself, whatever happens to this anchor).
    static func dismantleNSView(_ view: AnchorView, coordinator: AtticDropdownPresenter) {
        view.onWindow = nil
        coordinator.closeAfterViewUpdate()
    }
}

extension View {
    /// Shows `content` in Attic's dropdown card while `isPresented`, its left
    /// edge on this view's, on the `prefer` side when there is room. Only
    /// for Attic's own pop-over lists; native menus stay native.
    func atticDropdown<Content: View>(isPresented: Binding<Bool>, prefer: AtticDropdownLayout.Side = .below,
                                      label: String, takesKeyboard: Bool = true, contentHasCard: Bool = false, contentHeight: CGFloat? = nil,
                                      contentWidth: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) -> some View {
        modifier(AtticDropdownModifier(isPresented: isPresented, prefer: prefer, label: label, takesKeyboard: takesKeyboard, contentHasCard: contentHasCard, contentHeight: contentHeight, contentWidth: contentWidth, card: content))
    }
}

private struct AtticDropdownModifier<Card: View>: ViewModifier {
    @Binding var isPresented: Bool
    let prefer: AtticDropdownLayout.Side
    let label: String
    let takesKeyboard: Bool
    let contentHasCard: Bool
    let contentHeight: CGFloat?
    let contentWidth: CGFloat?
    let card: () -> Card

    @Environment(\.atticDesign) private var design

    func body(content: Content) -> some View {
        // The anchor exists only while the card is asked for: a row at rest
        // costs nothing (no AppKit view per row).
        content.background {
            if isPresented {
                AtticDropdownAnchor(isPresented: $isPresented, prefer: prefer, label: label, takesKeyboard: takesKeyboard, contentHasCard: contentHasCard, contentHeight: contentHeight, contentWidth: contentWidth,
                                    design: design, content: { AnyView(card()) })
                    .accessibilityHidden(true)
            }
        }
    }
}


private struct AtticDropdownRegisterKeysKey: EnvironmentKey {
    static let defaultValue: (((NSEvent) -> Bool)?) -> Void = { _ in }
}

private struct AtticDropdownContentHeightChangedKey: EnvironmentKey {
    static let defaultValue: ((CGFloat) -> Void)? = nil
}

private struct AtticDropdownContentWidthChangedKey: EnvironmentKey {
    static let defaultValue: ((CGFloat) -> Void)? = nil
}

private struct AtticDropdownWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private struct AtticDropdownHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// The open card's command chords, routed before AppKit menu equivalents.
    var atticDropdownRegisterKeys: (((NSEvent) -> Bool)?) -> Void {
        get { self[AtticDropdownRegisterKeysKey.self] }
        set { self[AtticDropdownRegisterKeysKey.self] = newValue }
    }

    var atticDropdownContentHeightChanged: ((CGFloat) -> Void)? {
        get { self[AtticDropdownContentHeightChangedKey.self] }
        set { self[AtticDropdownContentHeightChangedKey.self] = newValue }
    }

    /// A measured card's content asks for a wider card (a longer row).
    var atticDropdownContentWidthChanged: ((CGFloat) -> Void)? {
        get { self[AtticDropdownContentWidthChangedKey.self] }
        set { self[AtticDropdownContentWidthChangedKey.self] = newValue }
    }

    var atticDropdownWidth: CGFloat? {
        get { self[AtticDropdownWidthKey.self] }
        set { self[AtticDropdownWidthKey.self] = newValue }
    }

    var atticDropdownHeight: CGFloat? {
        get { self[AtticDropdownHeightKey.self] }
        set { self[AtticDropdownHeightKey.self] = newValue }
    }
}

struct AtticDropdownHighlightKey: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) {
        if let next = nextValue() { value = next }
    }
}

/// Known-height lists that fit stay plain. Cards measured as they change keep
/// their scroll container across height changes to preserve editing state.
/// Scrolling stops at a clean edge; the keyboard's highlighted row is brought wholly into view.
struct AtticDropdownViewport<Content: View>: View {
    var height: CGFloat?
    var highlighted: String? = nil
    var persistent = false
    @ViewBuilder let content: Content

    /// Rows cut off above and below (U-22): that edge fades, so a list cut
    /// short shows that it scrolls.
    @State private var cut = AtticDropdownViewportCut()

    var body: some View {
        if height != nil || persistent {
            ScrollViewReader { proxy in
                ScrollView(.vertical) { content.modifier(AtticUnfoldContent(scrolls: true)) }
                    .scrollIndicators(.never)
                    .scrollEdgeEffectHidden(true, for: .all)
                    .onScrollGeometryChange(for: AtticDropdownViewportCut.self) { geometry in
                        AtticDropdownViewportCut(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                                                 content: geometry.contentSize.height,
                                                 visible: geometry.containerSize.height)
                    } action: { _, next in
                        if next != cut { cut = next }
                    }
                    .mask { AtticDropdownViewportFade(cut: cut) }
                    // A height limit means the rows run on below it: say so
                    // from the first frame (the scroll reports only changes).
                    .onAppear { if height != nil, cut == AtticDropdownViewportCut() { cut.below = true } }
                    .frame(height: height)
                    .fixedSize(horizontal: false, vertical: height == nil)
                    .onAppear { if let highlighted { proxy.scrollTo(highlighted) } }
                    .onChange(of: highlighted) { _, id in
                        guard let id, !AtticListHighlight.isPointerMove(NSApp.currentEvent) else { return }
                        proxy.scrollTo(id)
                    }
                    .onPreferenceChange(AtticDropdownHighlightKey.self) { title in
                        guard let title, !AtticListHighlight.isPointerMove(NSApp.currentEvent) else { return }
                        proxy.scrollTo(title)
                    }
            }
        } else {
            content.modifier(AtticUnfoldContent())
        }
    }
}

/// Which of a scrolling list's edges have rows past them.
struct AtticDropdownViewportCut: Equatable {
    var above = false
    var below = false

    init() {}

    /// From the scroll's offset (0 at the top), its content's height and
    /// the height shown; half a point of slack.
    init(offset: CGFloat, content: CGFloat, visible: CGFloat) {
        above = offset > 0.5
        below = content - visible - offset > 0.5
    }

    /// How far the fade reaches in from a cut edge: most of a row, so the
    /// last whole row stays readable and the one past it plainly goes on.
    static let fade: CGFloat = 20
}

private struct AtticDropdownViewportFade: View {
    let cut: AtticDropdownViewportCut

    var body: some View {
        let fade = AtticDropdownViewportCut.fade
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(cut.above ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                .frame(height: fade)
            Color.black
            LinearGradient(colors: [.black, .black.opacity(cut.below ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: fade)
        }
        .animation(AtticMotionScale.easeOut(AtticMotionScale.fast), value: cut)
    }
}

/// SwiftUI has no public menu-item role. Supply its AppKit accessibility
/// representation while keeping the visible button and key routing intact.
///
/// As in a native menu, `selected` (`AXSelected`) is the list's one
/// highlight, and the tick is the item's mark (`AXMenuItemMarkChar`): "✓"
/// for a checked row, "-" for a part-checked one (some of the selected
/// tasks), none otherwise.
struct AtticDropdownMenuItem: NSViewRepresentable {
    let label: String
    let selected: Bool
    var check: AtticCheckState?
    var position: Int?
    var count: Int?
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    /// The menu item's mark attribute (HIServices' `kAXMenuItemMarkCharAttribute`).
    nonisolated static let markCharAttribute = NSAccessibility.Attribute(rawValue: "AXMenuItemMarkChar")

    static func markChar(_ check: AtticCheckState?) -> String? {
        switch check {
        case .on: "✓"
        case .mixed: "-"
        case .off, nil: nil
        }
    }

    final class ItemView: NSView {
        var action: (() -> Void)?
        /// The tick, as a native menu item reports it.
        var markChar: String?

        override func accessibilityPerformPress() -> Bool {
            guard isAccessibilityEnabled(), let action else { return false }
            action()
            return true
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        // The NSAccessibility protocol has no menu-item mark, so the item
        // answers the attribute itself, as AppKit's own menu items do. The
        // accessibility server asks on the main thread.
        @available(macOS, deprecated: 10.10, message: "Only the accessibility server calls it")
        override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
            let names = super.accessibilityAttributeNames()
            return names.contains(AtticDropdownMenuItem.markCharAttribute) ? names : names + [AtticDropdownMenuItem.markCharAttribute]
        }

        @available(macOS, deprecated: 10.10, message: "Only the accessibility server calls it")
        override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
            guard attribute == AtticDropdownMenuItem.markCharAttribute else { return super.accessibilityAttributeValue(attribute) }
            return MainActor.assumeIsolated { markChar }
        }
    }

    func makeNSView(context: Context) -> ItemView { ItemView() }
    func updateNSView(_ view: ItemView, context: Context) {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.menuItem)
        view.setAccessibilityLabel(label)
        view.setAccessibilitySelected(selected)
        view.setAccessibilityEnabled(enabled)
        view.markChar = Self.markChar(check)
        var value = check == .mixed ? String(localized: "some selected tasks") : ""
        if let position, let count {
            value += (value.isEmpty ? "" : ", ") + String(localized: "\(position) of \(count)")
            view.setAccessibilityIndex(position - 1)
        }
        view.setAccessibilityValue(value)
        view.action = action
    }
}
