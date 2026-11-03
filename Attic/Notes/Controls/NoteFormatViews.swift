import AppKit
import SwiftUI


/// The selection bar's entrance: the overlays' one recipe
/// (`AtticMotionScale.overlayTransition`): a fade, a 4 pt rise and a 0.96
/// grow from the anchored edge (M/S), leaving by opacity (F/E); the F/E
/// fade when motion is reduced.
enum NoteFormatMotion {
    static func transition(reduceMotion: Bool, from edge: VerticalEdge) -> AnyTransition {
        AtticMotionScale.overlayTransition(reduceMotion: reduceMotion, from: edge)
    }

    static func animation(reduceMotion: Bool) -> Animation? {
        AtticMotionScale.overlayAnimation(reduceMotion: reduceMotion)
    }

    /// The bottom row's coordinate space (Aa's frame is read in it).
    static let rowSpace = "notes-format-row-space"

    /// One channel of the format row's motion: a delay, then a spring from
    /// rest (SwiftUI's perceptual duration and bounce, as the app's motion
    /// presets give them).
    struct Spring: Equatable {
        var delay: Double = 0
        let response: Double
        var bounce: Double = 0

        init(delay: Double = 0, response: Double, bounce: Double = 0) {
            self.delay = delay
            self.response = response
            self.bounce = bounce
        }

        init(delay: Double = 0, _ spring: AtticMotionSpring) {
            self.init(delay: delay, response: spring.response, bounce: spring.bounce)
        }

        var animation: Animation { undelayed.delay(delay) }

        /// The spring alone (the caller starts it at `delay`).
        var undelayed: Animation { .spring(duration: response, bounce: bounce) }

        /// The spring's progress `t` seconds after it was asked to start
        /// (0 before its delay, settling on 1), as SwiftUI runs it.
        func value(at t: Double) -> Double {
            let t = t - delay
            guard t > 0 else { return 0 }
            let omega = 2 * Double.pi / response
            let zeta = 1 - bounce
            if zeta >= 1 { return 1 - (1 + omega * t) * exp(-omega * t) }
            let damped = omega * (1 - zeta * zeta).squareRoot()
            return 1 - exp(-zeta * omega * t) * (cos(damped * t) + zeta * omega / damped * sin(damped * t))
        }
    }

    /// Aa grows into the bar (p2-37 draft 1) on the app's own springs in
    /// the chosen feel (owner, 2026-10-06: "springy like the rest of the
    /// motion in our app"). The glass is `expand` (a card growing out of
    /// its button and back); the controls come in as a bar does
    /// (`popover`) and go with its leave; the neighbours slide into the
    /// row's sides on the glass's spring. Every delay is a share of those
    /// springs. Opening, both glass edges and both neighbours move together
    /// at once, and the controls come once it is about half grown. Closing,
    /// the controls start to go and the glass follows within half a leave;
    /// New note rides back in with the glass's trailing edge (the 8 pt gap
    /// held, as it was pushed out), and All notes and the status come back
    /// once the glass has cleared their places (A32). Animations: Reduced
    /// and Reduce Motion swap at once (the switch never asks for these).
    struct Plan: Equatable {
        /// The format controls leaving.
        let leave: Spring
        /// A neighbour coming back.
        let comeBack: Spring
        /// Both edges answer the click together on the same spring.
        let openLeading: Spring
        let openTrailing: Spring
        let openControls: Spring
        let closeControls: Spring
        let closeGrow: Spring
        /// New note's way back: the glass's own closing spring, so it
        /// follows the trailing edge in.
        let newNoteBack: Spring
        /// When All notes and the status come back, from the start of closing.
        let allNotesReturns: Double
        let statusReturns: Double

        init(_ tuning: AtticMotionTuning) {
            let leaving = tuning.leaveResponse
            leave = Spring(response: leaving, bounce: 0)
            comeBack = Spring(tuning.popover)
            let expand = tuning.expand.response
            openLeading = Spring(delay: 0, tuning.expand)
            openTrailing = openLeading
            openControls = Spring(delay: 0.55 * expand, tuning.popover)
            closeControls = leave
            // Half a leave: the controls are on their way out, and the glass
            // never stands wide and empty (A32: 0.8 of a leave held it still
            // for up to ten frames in Calm).
            closeGrow = Spring(delay: 0.4 * leaving, tuning.expand)
            newNoteBack = closeGrow
            allNotesReturns = closeGrow.delay + 0.35 * expand
            statusReturns = closeGrow.delay + 0.9 * expand
        }

        /// The plan in the feel in use now.
        static var current: Plan { Plan(.current) }
    }
}

// MARK: - Selection bar

/// The bar over a text selection (mockup p2-16 D, as p2-36 draws it): the
/// style menu, B I U S, link, highlight and inline code, each showing its
/// state.
struct NoteFormatBarView: View {
    @ObservedObject var model: NoteFormatModel
    @Environment(\.atticDesign) private var design

    var body: some View {
        ZStack {
            if model.barShown {
                bar
                    .transition(NoteFormatMotion.transition(reduceMotion: design.reduceMotion,
                                                            from: model.barBelow ? .top : .bottom))
            }
        }
        .animation(NoteFormatMotion.animation(reduceMotion: design.reduceMotion), value: model.barShown)
        .padding(AtticNoteFormatMetrics.shadowRoom)
        .accessibilityHidden(!model.barShown)
    }

    private var bar: some View {
        Group {
            if let cells = model.snapshot.cells { cellsBar(cells) } else { textBar }
        }
    }

    /// Over whole cells (spec § 4.3): the columns' alignment, B I U S,
    /// highlight, then copy, cut and clear.
    private func cellsBar(_ state: NoteCellSelectionState) -> some View {
        let focus = model.barKeyboardIndex
        let marks = NoteCommandCatalog.barMarks + [.mark(.highlight)]
        let title = state.alignment?.title ?? String(localized: "Align")
        return AtticFormatBarSurface {
            AtticCommandMenu(commands: model.alignMenu(), accessibilityLabel: String(localized: "Alignment, \(title)")) {
                AtticFormatStyleFace(title: title, isKeyboardFocused: focus == 0, isEnabled: true)
            }
            .help(String(localized: "Alignment"))
            .accessibilityIdentifier("notes-format-bar-align")
            AtticFormatGroup {
                // N2: the colours take exactly what B I U S and the nib give up.
                HStack(spacing: 0) { toggles(NoteCommandCatalog.barMarks, startingAt: 1) }
                    .modifier(NoteFormatFold(folded: model.highlightPalette == .selectionBar,
                                             width: CGFloat(NoteCommandCatalog.barMarks.count) * AtticNoteFormatMetrics.barToggleWidth))
                toggles([.mark(.highlight)], startingAt: marks.count)
            }
            AtticFormatGroup {
                ForEach(Array(NoteCellAction.allCases.enumerated()), id: \.offset) { offset, action in
                    AtticFormatToggle(systemName: action.symbolName, value: .off, label: action.title,
                                      help: action.shortcut.map { "\(action.title) \($0)" } ?? action.title,
                                      width: AtticNoteFormatMetrics.barToggleWidth,
                                      isKeyboardFocused: focus == 1 + marks.count + offset, glyphSize: action.glyphSize,
                                      announcesState: false) {
                        model.runCells(action)
                    }
                    .accessibilityIdentifier("notes-format-bar-cells-\(action)")
                }
            }
        }
        .animation(NoteFormatFold.animation(reduceMotion: design.reduceMotion), value: model.highlightPalette)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Cells bar"))
        .accessibilityIdentifier("notes-format-bar")
    }

    /// N2 and N3 (Adaptive picks, 2026-11-01): Highlight's chevron widens
    /// into its colours and B I U S fold away; the Link cell widens into
    /// the address field and the style and B I U S fold away. The bar keeps
    /// its width, so nothing beside the widening moves: the colours take
    /// 4 pt less than what folds (the 4 pt stay after Code), and the field
    /// takes exactly what the style and B I U S give up.
    private var textBar: some View {
        let snapshot = model.snapshot
        let focus = model.barKeyboardIndex
        let m = AtticNoteFormatMetrics.self
        let paletteOpen = model.highlightPalette == .selectionBar
        let linkOpen = model.linkFieldOpen
        let inline = NoteCommandCatalog.barInline
        let marksStart = 1 + NoteCommandCatalog.barMarks.count
        return AtticFormatBarSurface {
            AtticCommandMenu(commands: model.styleMenu(from: .selectionBar),
                             accessibilityLabel: String(localized: "Style, \(NoteCommandCatalog.styleName(snapshot.paragraph))")) {
                AtticFormatStyleFace(title: NoteCommandCatalog.styleName(snapshot.paragraph),
                                     isKeyboardFocused: focus == 0,
                                     isEnabled: NoteCommandCatalog.styles.contains { snapshot.isEnabled($0) })
            }
            .help(String(localized: "Style"))
            .accessibilityIdentifier("notes-format-bar-style")
            .modifier(NoteFormatFold(folded: linkOpen))
            AtticFormatGroup { toggles(NoteCommandCatalog.barMarks, startingAt: 1) }
                .modifier(NoteFormatFold(folded: paletteOpen || linkOpen,
                                         width: CGFloat(NoteCommandCatalog.barMarks.count) * m.barToggleWidth))
            AtticFormatGroup {
                ForEach(Array(inline.enumerated()), id: \.offset) { offset, command in
                    if command == .mark(.link) {
                        NoteLinkCell(model: model, isKeyboardFocused: focus == marksStart + offset,
                                     fieldWidth: NoteLinkCell.fieldWidth(barWidth: model.barRestWidth))
                    } else {
                        NoteFormatToggle(model: model, command: command, surface: .selectionBar,
                                         width: m.barToggleWidth, isKeyboardFocused: focus == marksStart + offset)
                    }
                }
            }
            .padding(.trailing, paletteOpen ? Self.paletteSlack : 0)
            // The bar's 4 pt gaps after what folded close up too (a folded
            // control can't take them: a size never goes below 0).
            .padding(.leading, -m.barGroupGap * CGFloat(linkOpen ? 2 : (paletteOpen ? 1 : 0)))
        }
        .animation(NoteFormatFold.animation(reduceMotion: design.reduceMotion), value: paletteOpen)
        .animation(NoteFormatFold.animation(reduceMotion: design.reduceMotion), value: linkOpen)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Format bar"))
        .accessibilityIdentifier("notes-format-bar")
    }

    /// What the open colours leave of B I U S, the nib and its chevron.
    static var paletteSlack: CGFloat {
        let m = AtticNoteFormatMetrics.self
        let folded = CGFloat(NoteCommandCatalog.barMarks.count + 1) * m.barToggleWidth + m.barGroupGap + m.highlightChevronWidth
        return max(0, folded - NoteHighlightPalette.width)
    }

    private func toggles(_ commands: [NoteFormatCommand], startingAt start: Int) -> some View {
        ForEach(Array(commands.enumerated()), id: \.offset) { offset, command in
            NoteFormatToggle(model: model, command: command, surface: .selectionBar,
                             width: AtticNoteFormatMetrics.barToggleWidth,
                             isKeyboardFocused: model.barKeyboardIndex == start + offset)
        }
    }
}

/// One command as a toggle, from the snapshot.
struct NoteFormatToggle: View {
    @ObservedObject var model: NoteFormatModel
    let command: NoteFormatCommand
    let surface: NoteCommandSurface
    let width: CGFloat
    var height: CGFloat = AtticControlSize.smallHeight
    var isKeyboardFocused = false
    /// An action (outdent, indent): no on/off value.
    var announcesState = true

    var body: some View {
        let snapshot = model.snapshot
        let label = NoteCommandCatalog.menuTitle(command).replacingOccurrences(of: "…", with: "")
        Group {
            if command == .mark(.highlight) {
                // N-2 option A: a split button. The nib applies the one-click
                // colour; N2 (2026-11-01): the chevron widens it in place
                // into the six colours (it replaces the native menu).
                let open = model.highlightPalette == surface
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        AtticFormatToggle(value: snapshot.value(command), label: label, help: NoteFormatModel.help(command),
                                          width: width, height: height, isKeyboardFocused: isKeyboardFocused && !open,
                                          disabledReason: snapshot.disabledReason, action: run) { ink in
                            AtticHighlightGlyph(ink: ink, swatch: model.highlightSwatch)
                        }
                        // On the nib alone: the chevron and the colours keep their own.
                        .accessibilityIdentifier(NoteCommandRouter.identifier(command))
                        NoteHighlightColourButton(model: model, surface: surface, height: height)
                    }
                    .opacity(open ? 0 : 1)
                    .allowsHitTesting(!open)
                    .accessibilityHidden(open)
                    NoteHighlightPalette(model: model, surface: surface, height: height)
                        .opacity(open ? 1 : 0)
                        .allowsHitTesting(open)
                        .accessibilityHidden(!open)
                }
                .frame(width: open ? NoteHighlightPalette.width : width + AtticNoteFormatMetrics.highlightChevronWidth,
                       alignment: .leading)
            } else {
                AtticFormatToggle(systemName: NoteCommandCatalog.symbol(command), value: snapshot.value(command),
                                  label: label, help: NoteFormatModel.help(command), width: width, height: height,
                                  isKeyboardFocused: isKeyboardFocused, disabledReason: snapshot.disabledReason,
                                  announcesState: announcesState, action: run)
                    .accessibilityIdentifier(NoteCommandRouter.identifier(command))
            }
        }
        .disabled(!snapshot.isEnabled(command))
    }

    private func run() { model.run(command, from: surface) }
}

/// The highlighter's chevron (N-2 option A): the colour menu under it.
struct NoteHighlightColourButton: View {
    @ObservedObject var model: NoteFormatModel
    let surface: NoteCommandSurface
    var height: CGFloat = AtticControlSize.smallHeight

    @State private var hovered = false

    /// The open colours' own chevron (pointing back), which folds them.
    var folds = false

    var body: some View {
        let m = AtticNoteFormatMetrics.self
        let enabled = model.snapshot.isEnabled(.mark(.highlight))
        Button {
            model.toggleHighlightPalette(on: surface)
        } label: {
            AtticIcon(systemName: folds ? "chevron.up" : "chevron.down", size: m.highlightChevronSize, weight: .semibold,
                      ink: enabled ? (hovered ? .body : .chevron) : .disabledIcon)
                .frame(width: m.highlightChevronWidth, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!enabled)
        .onHover { hovered = $0 }
        .help(String(localized: "Highlight colour"))
        .accessibilityLabel(String(localized: "Highlight colour"))
        .accessibilityValue(folds ? String(localized: "expanded") : String(localized: "collapsed"))
        .accessibilityIdentifier(folds ? "notes-format-highlight-colour-fold" : "notes-format-highlight-colour")
    }
}

// MARK: - Widening in place (Adaptive picks N1–N3, 2026-11-01)

/// A control making room for its neighbour's widening: its width goes to
/// 0, it fades, and the pointer, the keyboard ring and VoiceOver skip it
/// until it comes back exactly as it was. `width` nil keeps its natural
/// width while shown. A stack's gap after it is closed up by the next
/// control (`padding(.leading:)` below 0).
struct NoteFormatFold: ViewModifier {
    let folded: Bool
    var width: CGFloat?

    /// The app's expand preset (a card growing out of its button); Reduce
    /// Motion: at once.
    static func animation(reduceMotion: Bool) -> Animation? {
        AtticMotionPreset.expand.animation(reduceMotion: reduceMotion)
    }

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: folded ? 0 : width, alignment: .leading)
            // Clipped a little outside its own frame: a focus ring still
            // shows at rest, and nothing spills over a neighbour as it folds.
            .clipShape(Rectangle().inset(by: -AtticControlSize.capsuleInset))
            .opacity(folded ? 0 : 1)
            .allowsHitTesting(!folded)
            .accessibilityHidden(folded)
    }
}

/// N2: the highlighter widened into its six colours in the app's order
/// (Yellow, Green, Blue, Pink, Purple, Grey), 20 pt cells with the
/// highlight's square swatch, the selection's colour marked, then the
/// chevron that folds them back. One click picks and folds.
struct NoteHighlightPalette: View {
    @ObservedObject var model: NoteFormatModel
    let surface: NoteCommandSurface
    var height: CGFloat = AtticControlSize.smallHeight

    @Environment(\.atticDesign) private var design

    /// 20 pt cells (the draft's 40 px): the six with the chevron take
    /// 132 pt, 4 pt less than B I U S, the nib and its chevron.
    static let cellWidth: CGFloat = 20
    static var width: CGFloat {
        CGFloat(NoteHighlightColour.menuOrder.count) * cellWidth + AtticNoteFormatMetrics.highlightChevronWidth
    }

    var body: some View {
        let current = model.currentHighlight
        let keyboard = surface == .selectionBar ? model.paletteKeyboardIndex : nil
        HStack(spacing: 0) {
            ForEach(Array(NoteHighlightColour.menuOrder.enumerated()), id: \.offset) { index, colour in
                AtticFormatToggle(value: current == colour ? .on : .off, label: colour.title, help: colour.title,
                                  width: Self.cellWidth, height: height, isKeyboardFocused: keyboard == index,
                                  action: { model.pickHighlight(colour, from: surface) }) { _ in
                    NoteHighlightSwatchFace(colour: colour)
                }
                .accessibilityIdentifier("notes-format-highlight-\(colour.rawValue)")
            }
            NoteHighlightColourButton(model: model, surface: surface, height: height, folds: true)
        }
        .disabled(!model.snapshot.isEnabled(.mark(.highlight)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Highlight colours"))
        .accessibilityIdentifier("notes-format-highlight-colours")
    }
}

/// A colour's square swatch: the menu's chip (`NoteHighlightSwatch`), its
/// wash with a hairline rim.
struct NoteHighlightSwatchFace: View {
    let colour: NoteHighlightColour
    @Environment(\.atticDesign) private var design

    var body: some View {
        let side = NoteHighlightSwatch.size
        let shape = Squircle(cornerRadius: 3, exponent: AtticShape.surfaceExponent)
        let dark = design.tokens.context.mode == .dark
        shape.fill(design.tokens.highlightMarker(colour).color)
            .overlay(shape.strokeBorder(Color(white: dark ? 1 : 0, opacity: 0.18), lineWidth: 0.5))
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

/// N3: the bar's Link cell, which widens into the address field while the
/// link is being set (the style and B I U S fold away, Highlight and Code
/// stay). Return applies; Esc or a click elsewhere closes it; there is no
/// ×. On a link, Remove Link is a small icon at the field's end. A bad
/// address rings the field red and VoiceOver hears why.
struct NoteLinkCell: View {
    @ObservedObject var model: NoteFormatModel
    var isKeyboardFocused = false
    let fieldWidth: CGFloat

    /// The field's width: the bar's laid-out width at rest less its insets
    /// (4 + 4, and the 4 pt trailing room) and Highlight with Code
    /// (24 + 12 + 24).
    static func fieldWidth(barWidth: CGFloat) -> CGFloat {
        let m = AtticNoteFormatMetrics.self
        let rest = AtticControlSize.capsuleInset * 2 + m.barTrailingRoom
            + m.barToggleWidth * 2 + m.highlightChevronWidth
        return max(m.barToggleWidth, barWidth - rest)
    }

    var body: some View {
        let open = model.linkFieldOpen
        let m = AtticNoteFormatMetrics.self
        ZStack(alignment: .leading) {
            NoteFormatToggle(model: model, command: .mark(.link), surface: .selectionBar,
                             width: m.barToggleWidth, isKeyboardFocused: isKeyboardFocused && !open)
                .opacity(open ? 0 : 1)
                .allowsHitTesting(!open)
                .accessibilityHidden(open)
            if open, let card = model.linkCard {
                NoteLinkField(model: card, width: fieldWidth)
                    .transition(.opacity)
            }
        }
        .frame(width: open ? fieldWidth : m.barToggleWidth, alignment: .leading)
    }
}

/// The address field itself (N3), on the card model's text, error and
/// actions (the same commit, remove and cancel the link card used).
struct NoteLinkField: View {
    @ObservedObject var model: NoteFormatCardModel
    let width: CGFloat

    @FocusState private var focused: Bool
    @Environment(\.atticDesign) private var design

    var body: some View {
        let height = AtticControlSize.smallHeight
        let shape = AtticControlShape.shape(cornerRadius: AtticRadius.control(height: height), exponent: AtticShape.controlExponent)
        let hasLink: Bool = if case .link(true) = model.card { true } else { false }
        HStack(spacing: 5) {
            AtticIcon(systemName: "link", size: AtticSmallControlMetrics.iconSize - 2, weight: .regular, ink: .helper)
                .accessibilityHidden(true)
            TextField("", text: $model.linkText,
                      prompt: Text(verbatim: String(localized: "Paste or type a link"))
                          .foregroundStyle(design.tokens.color(.placeholder)))
                .textFieldStyle(.plain)
                .font(AtticTextStyle.controlLabel.font)
                .focused($focused)
                .onSubmit { model.submitLink() }
                .onExitCommand { model.onCancel?() }
                .accessibilityLabel(String(localized: "Link address"))
                .accessibilityIdentifier("notes-link-field")
            if hasLink {
                Button { model.onRemoveLink?() } label: {
                    AtticIcon(systemName: "xmark.circle", size: AtticSmallControlMetrics.iconSize - 2, weight: .regular,
                              ink: .helper)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle().inset(by: -AtticControlSize.hitOutset(for: 16)))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(String(localized: "Remove Link"))
                .accessibilityLabel(String(localized: "Remove Link"))
                .accessibilityIdentifier("notes-link-remove")
            }
        }
        .padding(.leading, AtticNoteFormatMetrics.barStylePadding)
        .padding(.trailing, hasLink ? 3 : AtticNoteFormatMetrics.barStylePadding)
        .frame(width: width, height: height, alignment: .leading)
        .background(shape.fill(design.tokens.chipHover.color))
        .overlay(shape.strokeBorder(design.tokens.color(.dueText), lineWidth: model.linkError == nil ? 0 : 0.75))
        .onAppear { focused = true }
        .onChange(of: model.linkError) { _, error in
            guard let error else { return }
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: error, .priority: NSAccessibilityPriorityLevel.high.rawValue
            ])
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Link"))
        .accessibilityIdentifier("notes-link-bar-field")
    }
}

/// N1: the format row's Style pill widened into Title · Heading ·
/// Subheading · Body · Mono on a faint capsule, each name in its style at
/// the design's Aa-sheet sizes (the style list's preview fonts need about
/// 300 pt and do not fit a 320 pt panel's row), the current one marked.
struct NoteFormatStyleStrip: View {
    @ObservedObject var model: NoteFormatModel

    @Environment(\.atticDesign) private var design

    /// The Aa sheet's sizes, halved from its px: 24, 21, 19, 20 and 18.
    static func font(_ command: NoteFormatCommand) -> NSFont {
        switch command {
        case .paragraph(.heading(1)): .systemFont(ofSize: 12, weight: .bold)
        case .paragraph(.heading(2)): .systemFont(ofSize: 10.5, weight: .semibold)
        case .paragraph(.heading(3)): .systemFont(ofSize: 9.5, weight: .semibold)
        case .paragraph(.mono): .monospacedSystemFont(ofSize: 9, weight: .regular)
        default: .systemFont(ofSize: 10, weight: .regular)
        }
    }

    /// 7 pt either side of each name (the sheet's 8 would need 260 pt of a
    /// 320 pt panel's 252 to 256), 1 pt apart.
    static let padding: CGFloat = 7
    static let gap: CGFloat = 1

    /// The pill's names (Mono, not Code Block).
    static func name(_ command: NoteFormatCommand) -> String {
        if case let .paragraph(style) = command { return NoteCommandCatalog.styleName(style) }
        return command.title
    }

    static func cellWidth(_ command: NoteFormatCommand) -> CGFloat {
        ceil((name(command) as NSString).size(withAttributes: [.font: font(command)]).width) + padding * 2
    }

    /// The five names' width, as laid out.
    static var width: CGFloat {
        let styles = NoteFormatModel.stripStyles
        return styles.map(cellWidth).reduce(0, +) + gap * CGFloat(styles.count - 1)
    }

    var body: some View {
        let height = AtticNoteFormatMetrics.rowCellHeight
        let radius = AtticRadius.control(height: height)
        let styles = NoteFormatModel.stripStyles
        HStack(spacing: Self.gap) {
            ForEach(Array(styles.enumerated()), id: \.offset) { index, command in
                NoteFormatStyleStripCell(model: model, command: command, height: height,
                                         isKeyboardFocused: model.styleStripKeyboardIndex == index)
            }
        }
        .background(AtticControlShape.shape(cornerRadius: radius, exponent: AtticShape.controlExponent).fill(design.tokens.chipHover.color))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Style"))
        .accessibilityIdentifier("notes-format-style-strip")
    }
}

private struct NoteFormatStyleStripCell: View {
    @ObservedObject var model: NoteFormatModel
    let command: NoteFormatCommand
    let height: CGFloat
    let isKeyboardFocused: Bool

    @Environment(\.atticDesign) private var design
    @State private var hovered = false

    var body: some View {
        let snapshot = model.snapshot
        let on = snapshot.value(command) == .on
        let enabled = snapshot.isEnabled(command)
        let radius = AtticRadius.control(height: height)
        let fill: AtticRGBA = on ? design.tokens.chipSelected : (hovered && enabled ? design.tokens.chipHover : .clear)
        Button { model.pickStripStyle(command) } label: {
            Text(verbatim: NoteFormatStyleStrip.name(command))
                .font(Font(NoteFormatStyleStrip.font(command)))
                .foregroundStyle(design.tokens.color(enabled ? .heading : .disabledText))
                .lineLimit(1)
                .fixedSize()
                .frame(width: NoteFormatStyleStrip.cellWidth(command), height: height)
                .background(AtticControlShape.shape(cornerRadius: radius, exponent: AtticShape.controlExponent).fill(fill.color))
                .contentShape(AtticControlShape.shape(cornerRadius: radius, exponent: AtticShape.controlExponent))
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        .disabled(!enabled)
        .atticFocusRing(isKeyboardFocused, cornerRadius: radius)
        .onHover { hovered = $0 }
        .help(NoteFormatModel.help(command))
        .accessibilityLabel(NoteFormatStyleStrip.name(command))
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("notes-format-strip-" + NoteCommandRouter.identifier(command))
    }
}

// MARK: - The format row (OD-14)

/// Aa's format row (p2-36 draft 1): the bottom row itself, turned into one
/// row of paragraph formatting while it is open. The caret line's style as
/// a pill (its list holds Title … Mono, each in its own style), then
/// Bulleted, Numbered, Checklist and Quote showing which applies, outdent
/// and indent, and ✕. Nothing floats over the note; marks stay on the
/// selection bar. ⌘T or ⌃Tab put the keyboard on it (← → Tab move, Return
/// or Space press, Esc closes); the text keeps the caret throughout.
struct NoteFormatRowView: View {
    @ObservedObject var model: NoteFormatModel
    /// While it grows out of Aa or returns into it (nil at rest).
    var growth: AtticFormatRowGrowth?
    /// The controls' fade (1 at rest).
    var controlsOpacity: Double = 1
    let onClose: () -> Void

    /// The row's width (the bottom row's).
    @State private var width: CGFloat = 0
    @Environment(\.atticDesign) private var design

    var body: some View {
        // A long style name ("Subheading") in a narrow panel: 24 pt cells.
        let m = AtticNoteFormatMetrics.self
        let roomy = width == 0 || Self.minimumWidth(snapshot: model.snapshot, toggleWidth: m.rowToggleWidth, compact: false) <= width
        Group {
            if let table = model.snapshot.table {
                tableRow(table, toggleWidth: m.rowToggleWidth)
            } else {
                row(toggleWidth: roomy ? m.rowToggleWidth : m.rowCompactToggleWidth)
            }
        }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
                if abs(new - width) > 0.5 { width = new }
            }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Format"))
        .accessibilityIdentifier("notes-format-row")
    }

    private func row(toggleWidth: CGFloat) -> some View {
        let m = AtticNoteFormatMetrics.self
        let focus = model.rowKeyboardIndex
        let lists = NoteCommandCatalog.lists
        let indents = NoteCommandCatalog.indents
        let compact = toggleWidth < m.rowToggleWidth
        let marks = NoteCommandCatalog.barMarks
        let inline = NoteCommandCatalog.barInline
        return AtticFormatRowSurface(growth: growth, contentOpacity: controlsOpacity) {
            if model.snapshot.hasTextSelection {
                // D-06: with text selected the row takes the selection bar's
                // marks (the whole row: the style returns with the caret), so
                // only one format surface shows. N2: the highlighter's colours
                // fold B I U S away here too.
                HStack(spacing: 0) {
                    AtticFormatGroup {
                        ForEach(Array(marks.enumerated()), id: \.offset) { offset, command in
                            NoteFormatToggle(model: model, command: command, surface: .formatBar, width: toggleWidth,
                                             height: m.rowCellHeight, isKeyboardFocused: focus == offset)
                        }
                    }
                    AtticFormatSeparator(compact: compact)
                }
                .modifier(NoteFormatFold(folded: model.highlightPalette == .formatBar))
                AtticFormatGroup {
                    ForEach(Array(inline.enumerated()), id: \.offset) { offset, command in
                        NoteFormatToggle(model: model, command: command, surface: .formatBar, width: toggleWidth,
                                         height: m.rowCellHeight, isKeyboardFocused: focus == marks.count + offset)
                    }
                }
            } else {
            NoteFormatStylePill(model: model, isKeyboardFocused: focus == 0)
            // N1: while the pill stands widened into its styles, the lists
            // and the indents fold away (✕ stays).
            HStack(spacing: 0) {
                AtticFormatSeparator(compact: compact)
                AtticFormatGroup {
                    ForEach(Array(lists.enumerated()), id: \.offset) { offset, command in
                        // Table inserts (it is not a state of the line).
                        NoteFormatToggle(model: model, command: command, surface: .formatBar, width: toggleWidth,
                                         height: m.rowCellHeight, isKeyboardFocused: focus == 1 + offset,
                                         announcesState: command != .table)
                    }
                }
                AtticFormatSeparator(compact: compact)
                AtticFormatGroup {
                    ForEach(Array(indents.enumerated()), id: \.offset) { offset, command in
                        NoteFormatToggle(model: model, command: command, surface: .formatBar, width: toggleWidth,
                                         height: m.rowCellHeight, isKeyboardFocused: focus == 1 + lists.count + offset,
                                         announcesState: false)
                    }
                }
            }
            .modifier(NoteFormatFold(folded: model.rowStyleListOpen))
            }
            Spacer(minLength: 0)
            AtticFormatToggle(systemName: "xmark", value: .off, label: String(localized: "Close Format"),
                              help: String(localized: "Close (Esc)"), width: toggleWidth, height: m.rowCellHeight,
                              isKeyboardFocused: focus == NoteFormatRowItem.items(inTable: false, textSelected: model.snapshot.hasTextSelection).count - 1,
                              announcesState: false, action: onClose)
                .accessibilityIdentifier("notes-format-row-close")
        }
        .animation(NoteFormatFold.animation(reduceMotion: design.reduceMotion), value: model.rowStyleListOpen)
        .animation(NoteFormatFold.animation(reduceMotion: design.reduceMotion), value: model.highlightPalette)
    }

    /// The row in a table (sheet 3, panel 2): Table ⌄, add a row and a
    /// column, delete the row and the column, ✕. The same capsule and
    /// motion; the cell's marks stay on the selection bar.
    private func tableRow(_ state: NoteTableToolsState, toggleWidth: CGFloat) -> some View {
        let m = AtticNoteFormatMetrics.self
        let focus = model.rowKeyboardIndex
        let tools = NoteTableTool.allCases
        return AtticFormatRowSurface(growth: growth, contentOpacity: controlsOpacity) {
            NoteFormatTablePill(model: model, isKeyboardFocused: focus == 0)
            AtticFormatSeparator()
            AtticFormatGroup {
                ForEach(Array(tools.prefix(2).enumerated()), id: \.offset) { offset, tool in
                    tableToggle(tool, width: toggleWidth, focused: focus == 1 + offset, enabled: true)
                }
            }
            AtticFormatSeparator()
            AtticFormatGroup {
                ForEach(Array(tools.suffix(2).enumerated()), id: \.offset) { offset, tool in
                    tableToggle(tool, width: toggleWidth, focused: focus == 3 + offset, enabled: true)
                }
            }
            Spacer(minLength: 0)
            AtticFormatToggle(systemName: "xmark", value: .off, label: String(localized: "Close Format"),
                              help: String(localized: "Close (Esc)"), width: toggleWidth, height: m.rowCellHeight,
                              isKeyboardFocused: focus == NoteFormatRowItem.table.count - 1, announcesState: false,
                              action: onClose)
                .accessibilityIdentifier("notes-format-row-close")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Table"))
    }

    private func tableToggle(_ tool: NoteTableTool, width: CGFloat, focused: Bool, enabled: Bool) -> some View {
        let help = tool.shortcut.map { "\(tool.title) \($0)" } ?? tool.title
        return AtticFormatToggle(value: .off, label: tool.title, help: help, width: width,
                                 height: AtticNoteFormatMetrics.rowCellHeight, isKeyboardFocused: focused,
                                 announcesState: false, action: { model.runTable(tool) }) { ink in
            AtticTableToolGlyph(kind: tool.glyph, ink: ink)
        }
        .disabled(!enabled)
        .accessibilityIdentifier("notes-format-row-table-\(tool)")
    }

    /// Every name the style pill can show (the styles, the lists and
    /// "Style" for a mixed selection).
    static var stylePillNames: [String] {
        let styles = (NoteCommandCatalog.styles + NoteCommandCatalog.lists).compactMap { command -> NoteParagraphStyle? in
            if case let .paragraph(style) = command { style } else { nil }
        }
        return [NoteCommandCatalog.styleName(nil)] + styles.map(NoteCommandCatalog.styleName)
    }

    /// U-17: Aa's style pill is as wide as its longest name in every state,
    /// so the lists, the indents and their spacing never move with the style.
    static let stylePillWidth: CGFloat = {
        let m = AtticNoteFormatMetrics.self
        let font = AtticTextStyle.controlLabel.nsFont
        let label = stylePillNames.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 0
        return label + 4 + m.barStyleChevron + 2 + m.barStylePadding * 2
    }()

    /// What the row needs before its flexible gap: the inset, the pill, two
    /// lines and the cells (the pill's width is the same for every style).
    static func minimumWidth(snapshot: NoteFormatSnapshot, toggleWidth: CGFloat, compact: Bool? = nil) -> CGFloat {
        let m = AtticNoteFormatMetrics.self
        let compact = compact ?? (toggleWidth < m.rowToggleWidth)
        let pill = stylePillWidth
        let separators = 2 * (1 + (compact ? m.rowCompactSeparatorPadding : m.rowSeparatorPadding) * 2)
        if snapshot.hasTextSelection {
            // The marks row: seven marks with the highlighter's chevron, one
            // line between the groups, and ✕ (D-06).
            let cells = CGFloat(NoteFormatRowItem.marks.count) * toggleWidth + m.highlightChevronWidth
            return ceil(AtticControlSize.capsuleInset * 2 + separators / 2 + cells)
        }
        let cells = CGFloat(NoteFormatRowItem.all.count - 1) * toggleWidth
        return ceil(AtticControlSize.capsuleInset * 2 + pill + separators + cells)
    }
}

/// The bottom row or, while Aa's format row is open, the format row in
/// its place (they take turns in one place; nothing floats over the note).
///
/// Opening, Aa's own glass becomes the row's and grows into the bar (p2-37
/// draft 1, `NoteFormatMotion.Plan`): both edges move together, New note
/// slides right and All notes left, the status clears at once, and controls come once the glass is
/// wide. They are the glass's content, so nothing is drawn under it. ✕ or
/// Esc runs it back into Aa. Animations: Reduced
/// and Reduce Motion swap at once. While either is on its way out it is
/// hidden from VoiceOver and the pointer, and once open the bottom row is
/// disabled. The motion is this view's own state: the page and the note
/// never redraw for it.
struct NoteFormatRowSwitch<Row: View>: View {
    @ObservedObject var state: NoteFormatRowState
    /// The format model of the note on screen (read as the row opens).
    let model: () -> NoteFormatModel?
    @ViewBuilder let row: Row

    @Environment(\.atticDesign) private var design
    @State private var phase = NoteFormatRowPhase.closed
    @State private var channels = NoteFormatRowChannels.closed
    @State private var shownModel: NoteFormatModel?
    @State private var geometry = NoteFormatRowGeometry()
    @State private var source: CGRect = .zero
    @State private var width: CGFloat = 0
    /// The current motion; pending neighbour changes of older ones lapse.
    @State private var motionToken = 0
    @State private var allNotesGone = false
    @State private var newNoteGone = false
    @State private var statusHidden = false
    /// The row's surface is in the tree, dormant (no glass, nothing drawn)
    /// while closed, so opening animates it on the very next frame.
    @State private var surfaceMounted = false

    var body: some View {
        // The bottom row decides the size; the format row's glass is laid
        // over it and never asks for room (it has a fixed width of its own:
        // as a sibling it held the whole page at its old width after
        // Settings narrowed the panel, A39 F08).
        let away = phase != .closed
        // Always in the tree (mounting it again as the row closes
        // stalled the first frames of the motion, A29 round 2); while the
        // row is open it is away, disabled and out of the keyboard loop.
        row
            // The room the bottom row is given, measured on the row itself.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
                if abs(new - width) > 0.5 { width = new }
            }
            .environment(\.noteFormatRowStage, NoteFormatRowStage(allNotes: channels.allNotes,
                                                                  newNoteAndStatus: channels.newNoteAndStatus,
                                                                  allNotesGone: allNotesGone,
                                                                  newNoteAndStatusGone: newNoteGone,
                                                                  statusHidden: statusHidden,
                                                                  sourceHidden: away))
            .environment(\.noteFormatRowGeometry, geometry)
            .disabled(phase == .open)
            .allowsHitTesting(!away)
            .accessibilityHidden(away)
            .overlay(alignment: .leading) {
                if let model = shownModel ?? model() {
                    let dormant = phase == .closed
                    NoteFormatRowView(model: model,
                                      growth: AtticFormatRowGrowth(source: source, rowWidth: width,
                                                                   leading: channels.leading, trailing: channels.trailing,
                                                                   sourceSymbol: NoteFormatRowSource.symbol),
                                      controlsOpacity: channels.controls) { state.close() }
                        .environment(\.atticControlGone, dormant)
                        .allowsHitTesting(!dormant && state.isOpen)
                        .accessibilityHidden(dormant || !state.isOpen)
                        .onAppear { surfaceMounted = true }
                        .onDisappear { surfaceMounted = false }
                }
            }
        .coordinateSpace(.named(NoteFormatMotion.rowSpace))
        .onChange(of: state.isOpen) { _, open in
            if open { self.open() } else { close() }
        }
        .onAppear {
            guard state.isOpen, let model = model() else { return }
            shownModel = model
            source = sourceFrame
            phase = .open
            channels = .open
            statusHidden = true
        }
    }

    /// Aa's frame in the row, or where it stands when it isn't measured.
    private var sourceFrame: CGRect {
        if geometry.source.width > 0 { return geometry.source }
        let size = AtticControlSize.panelButton
        return CGRect(x: width - size.width * 2 - AtticNoteMetrics.formatButtonGap, y: 0, width: size.width, height: size.height)
    }

    private func open() {
        guard let model = model() else { return }
        if design.reduceMotion {
            motionToken += 1
            instantly {
                shownModel = model
                source = sourceFrame
                phase = .open
                channels = .open
                allNotesGone = true
                newNoteGone = true
                statusHidden = true
            }
            return
        }
        if phase == .closed {
            // Aa's glass becomes the row's where Aa stands, in this frame,
            // and both edges move on the next. The surface is already
            // in the tree (dormant), so it animates from where it is; only if
            // it was not yet mounted does the motion wait one turn for it.
            motionToken += 1
            let mounted = surfaceMounted
            instantly {
                shownModel = model
                source = sourceFrame
                channels.leading = 0
                channels.trailing = 0
                channels.controls = 0
                statusHidden = true
                phase = .moving
            }
            if mounted {
                runOpen()
            } else {
                DispatchQueue.main.async { if state.isOpen { runOpen() } }
            }
        } else {
            runOpen()
        }
    }

    /// The neighbours' glass changes at the moment it should: an animation
    /// delay is not honoured by glass turning to or from the identity glass
    /// (it either jumped at once or lingered as a faint ring, A29 round 2),
    /// so each neighbour is sent away or back on its own clock with an
    /// undelayed animation. A newer motion cancels what is still pending.
    private func runOpen() {
        motionToken += 1
        let token = motionToken
        let plan = NoteFormatMotion.Plan.current
        // Both neighbours travel away from the growing glass on its spring,
        // including a reversal while either had begun coming back.
        if !statusHidden { instantly { statusHidden = true } }
        withAnimation(plan.openControls.animation) {
            channels.controls = 1
        }
        withAnimation(plan.openLeading.undelayed, completionCriteria: .logicallyComplete) {
            channels.leading = 1
            channels.trailing = 1
            channels.allNotes = 1
            channels.newNoteAndStatus = 1
        } completion: {
            guard motionToken == token, state.isOpen, phase == .moving else { return }
            instantly {
                phase = .open
                allNotesGone = true
                newNoteGone = true
            }
        }
    }

    private func close() {
        if design.reduceMotion || phase == .closed {
            motionToken += 1
            instantly {
                phase = .closed
                channels = .closed
                allNotesGone = false
                newNoteGone = false
                statusHidden = false
                shownModel = nil
            }
            return
        }
        if phase == .open { instantly { phase = .moving } }
        runClose()
    }

    private func runClose() {
        motionToken += 1
        let token = motionToken
        let plan = NoteFormatMotion.Plan.current
        withAnimation(plan.closeControls.animation) { channels.controls = 0 }
        if channels.allNotes > 0 {
            after(plan.allNotesReturns, token: token) {
                returnNeighbour(token: token, gone: $allNotesGone, spring: plan.comeBack) { channels.allNotes = 0 }
            }
        }
        if statusHidden {
            after(plan.statusReturns, token: token) {
                withAnimation(plan.comeBack.undelayed) { statusHidden = false }
            }
        }
        // New note's glass comes back whole but still beyond the row's
        // edge (nothing of it is drawn yet), and rides in with the glass.
        if newNoteGone { instantly { newNoteGone = false } }
        withAnimation(plan.closeGrow.animation, completionCriteria: .logicallyComplete) {
            channels.leading = 0
            channels.trailing = 0
            channels.newNoteAndStatus = 0
        } completion: {
            guard motionToken == token, !state.isOpen, phase == .moving else { return }
            // Aa takes its glass back; a neighbour still due keeps its clock.
            instantly {
                phase = .closed
                channels.leading = 0
                channels.trailing = 0
                channels.controls = 0
                shownModel = nil
            }
        }
    }

    /// A neighbour comes back: restore its glass while it is clipped
    /// outside its slot, then spring it in on the next turn.
    private func returnNeighbour(token: Int, gone: Binding<Bool>, spring plan: NoteFormatMotion.Spring,
                                 _ change: @escaping () -> Void) {
        let spring = plan.undelayed
        if gone.wrappedValue {
            instantly { gone.wrappedValue = false }
            DispatchQueue.main.async {
                guard motionToken == token else { return }
                withAnimation(spring, change)
            }
        } else {
            withAnimation(spring, change)
        }
    }

    /// Runs `work` after `delay` unless a newer motion has started.
    private func after(_ delay: Double, token: Int, _ work: @escaping () -> Void) {
        guard delay > 0 else { work(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if motionToken == token { work() }
        }
    }

    private func instantly(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
}

/// Where the format row is: the bottom row alone, the two on their way
/// (opening or closing), or the row alone (the bottom row still in the
/// tree, away and disabled).
enum NoteFormatRowPhase: Equatable {
    case closed, moving, open
}

/// The format row's motion channels, each 0 (the bottom row) to 1 (the
/// format row), driven by `NoteFormatMotion`'s springs.
struct NoteFormatRowChannels: Equatable {
    /// Aa's glass's leading edge, from Aa's (0) to the row's (1).
    var leading: CGFloat
    /// The trailing edge (New note's side).
    var trailing: CGFloat
    /// The row's controls.
    var controls: Double
    /// All notes' outward travel.
    var allNotes: Double
    /// New note's outward travel and the note status's return.
    var newNoteAndStatus: Double

    static let closed = NoteFormatRowChannels(leading: 0, trailing: 0, controls: 0, allNotes: 0, newNoteAndStatus: 0)
    static let open = NoteFormatRowChannels(leading: 1, trailing: 1, controls: 1, allNotes: 1, newNoteAndStatus: 1)
}

/// What the bottom row's pieces read while the format row comes and goes.
struct NoteFormatRowStage: Equatable {
    var allNotes: Double = 0
    var newNoteAndStatus: Double = 0
    /// Gone and settled: no glass left at all (`atticControlGone`).
    var allNotesGone = false
    var newNoteAndStatusGone = false
    /// The status (plain text, under where the glass's leading edge goes
    /// first) is hidden at once as the row opens.
    var statusHidden = false
    /// Aa's glass is the format row's for now: Aa itself is not drawn.
    var sourceHidden = false
}

/// Aa's frame in the bottom row, kept without redrawing anything.
final class NoteFormatRowGeometry {
    var source: CGRect = .zero
}

private struct NoteFormatRowStageKey: EnvironmentKey {
    static let defaultValue = NoteFormatRowStage()
}

private struct NoteFormatRowGeometryKey: EnvironmentKey {
    static let defaultValue: NoteFormatRowGeometry? = nil
}

extension EnvironmentValues {
    var noteFormatRowStage: NoteFormatRowStage {
        get { self[NoteFormatRowStageKey.self] }
        set { self[NoteFormatRowStageKey.self] = newValue }
    }

    var noteFormatRowGeometry: NoteFormatRowGeometry? {
        get { self[NoteFormatRowGeometryKey.self] }
        set { self[NoteFormatRowGeometryKey.self] = newValue }
    }
}

/// The neighbours slide into their respective row edges as Aa grows.
/// The status is plain text and hides at once to clear the glass's path.
enum NoteFormatRowNeighbour {
    case allNotes, status, newNote

    /// A whole button and the Aa gap: enough to clear the row edge while
    /// preserving that gap beside Aa's moving trailing edge.
    static let exitDistance = AtticControlSize.panelButton.width + AtticNoteMetrics.formatButtonGap

    func offset(at progress: Double) -> CGFloat {
        let travel = Self.exitDistance * CGFloat(min(1, max(0, progress)))
        switch self {
        case .allNotes: return -travel
        case .newNote: return travel
        case .status: return 0
        }
    }

    /// What is left inside the slot after `offset(at:)`: the side the
    /// button travels toward is cut by the distance it has gone, so it
    /// passes under the row's edge.
    func reveal(at progress: Double) -> AtticControlReveal? {
        let travel = abs(offset(at: progress))
        switch self {
        case .allNotes: return AtticControlReveal(leading: travel)
        case .newNote: return AtticControlReveal(trailing: travel)
        case .status: return nil
        }
    }
}

private struct NoteFormatRowLeaving: ViewModifier {
    let neighbour: NoteFormatRowNeighbour
    @Environment(\.noteFormatRowStage) private var stage

    func body(content: Content) -> some View {
        let progress = neighbour == .allNotes ? stage.allNotes : stage.newNoteAndStatus
        let gone = neighbour == .allNotes ? stage.allNotesGone : stage.newNoteAndStatusGone
        if neighbour == .status {
            content.opacity(stage.statusHidden ? 0 : 1)
        } else {
            content
                .environment(\.atticControlAway, false)
                .environment(\.atticControlGone, gone)
                .modifier(NoteFormatRowSlide(neighbour: neighbour, progress: progress))
        }
    }
}

/// Clip at the button's outer slot edge, preserving vertical shadow room.
/// Clamping each interpolated frame prevents a returning spring from
/// overshooting inward into Aa's 8 pt gap. A glass container ignores the
/// clip on its members' glass (A32: the buttons were left half out over
/// the panel's margin, then vanished at once), so the button's glass
/// itself narrows to the part still inside its slot
/// (`atticControlReveal`); the clip remains for the drawn controls.
private struct NoteFormatRowSlide: ViewModifier, Animatable {
    let neighbour: NoteFormatRowNeighbour
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.atticControlReveal, neighbour.reveal(at: progress))
            .offset(x: neighbour.offset(at: progress))
            .padding(.vertical, AtticNoteFormatMetrics.shadowRoom)
            .clipped()
            .padding(.vertical, -AtticNoteFormatMetrics.shadowRoom)
    }
}

/// Aa: the format row's glass starts as Aa's, so Aa reports where it is
/// and is not drawn while the row's glass stands in for it.
struct NoteFormatRowSource: ViewModifier {
    static let symbol = "textformat"

    @Environment(\.noteFormatRowStage) private var stage
    @Environment(\.noteFormatRowGeometry) private var geometry

    func body(content: Content) -> some View {
        content
            .environment(\.atticControlAway, stage.sourceHidden)
            .environment(\.atticControlGone, stage.sourceHidden)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(NoteFormatMotion.rowSpace)) } action: { frame in
                geometry?.source = frame
            }
    }
}

extension View {
    /// A bottom-row control making way for the format row.
    func noteFormatRowLeaving(_ neighbour: NoteFormatRowNeighbour) -> some View {
        modifier(NoteFormatRowLeaving(neighbour: neighbour))
    }

    /// Aa, the format row's source.
    func noteFormatRowSource() -> some View {
        modifier(NoteFormatRowSource())
    }
}

/// The format row's style pill ("List ⌄"): it opens the style list (E1).
struct NoteFormatStylePill: View {
    @ObservedObject var model: NoteFormatModel
    var isKeyboardFocused = false

    var body: some View {
        let snapshot = model.snapshot
        let name = NoteCommandCatalog.styleName(snapshot.paragraph)
        let enabled = NoteCommandCatalog.styles.contains { snapshot.isEnabled($0) }
        let open = model.rowStyleListOpen
        // N1 (2026-11-01): the pill widens in place into its five styles
        // from its leading edge (it replaces the list over the note).
        ZStack(alignment: .leading) {
            Button { model.rowStyleListOpen = true } label: {
                AtticFormatStyleFace(title: name, isKeyboardFocused: isKeyboardFocused && !open, isEnabled: enabled,
                                     height: AtticNoteFormatMetrics.rowCellHeight, width: NoteFormatRowView.stylePillWidth)
            }
            .buttonStyle(AtticUndimmedButtonStyle())
            .focusEffectDisabled()
            .disabled(!enabled)
            .help(String(localized: "Style"))
            .accessibilityLabel(String(localized: "Style"))
            .accessibilityValue(name)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("notes-format-row-style")
            .opacity(open ? 0 : 1)
            .allowsHitTesting(!open)
            .accessibilityHidden(open)
            NoteFormatStyleStrip(model: model)
                .fixedSize()
                .opacity(open ? 1 : 0)
                .allowsHitTesting(open)
                .accessibilityHidden(!open)
        }
        .frame(width: open ? NoteFormatStyleStrip.width : NoteFormatRowView.stylePillWidth, alignment: .leading)
    }
}

/// Table ⌄ in Aa's row: the table's menu (E1).
struct NoteFormatTablePill: View {
    @ObservedObject var model: NoteFormatModel
    var isKeyboardFocused = false

    var body: some View {
        Button { model.rowTableMenuOpen = true } label: {
            AtticFormatStyleFace(title: String(localized: "Table"), isKeyboardFocused: isKeyboardFocused, isEnabled: true,
                                 height: AtticNoteFormatMetrics.rowCellHeight)
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .focusEffectDisabled()
        .help(String(localized: "Table"))
        .accessibilityLabel(String(localized: "Table"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("notes-format-row-table")
        .atticDropdown(isPresented: $model.rowTableMenuOpen, prefer: .above, label: String(localized: "Table"),
                       contentHeight: AtticDropdownMetrics.inset * 2
                           + AtticDropdownMetrics.rowHeight * CGFloat(NoteTableMenuItem.allCases.count)) {
            NoteTableMenuView(model: model)
        }
    }
}

/// The table's menu: Header Row ✓, Distribute Columns, Convert to Text,
/// Copy as Markdown, Delete Table. ↑ ↓ move, Return or Space choose, Esc closes.
struct NoteTableMenuView: View {
    @ObservedObject var model: NoteFormatModel
    @State private var highlighted: Int?
    @FocusState private var focused: Bool

    private var items: [NoteTableMenuItem] { NoteTableMenuItem.allCases }

    var body: some View {
        let header = model.snapshot.table?.headerRow ?? false
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                AtticDropdownRow(title: item.title, check: item == .headerRow ? (header ? .on : .off) : .off,
                                 isHighlighted: highlighted == index,
                                 titleInk: .heading,
                                 onHover: { inside in
                                     let next = AtticListHighlight.hovered(index, inside: inside, current: highlighted)
                                     if next != highlighted { highlighted = next }
                                 }, position: index + 1, itemCount: items.count) { model.runTableMenu(item) }
                    .accessibilityIdentifier("notes-table-menu-\(item)")
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .atticDropdownFocus($focused)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Table"))
        .accessibilityIdentifier("notes-table-menu")
        .onKeyPress(phases: .down) { press in
            switch press.key {
            case .downArrow: highlighted = min((highlighted ?? -1) + 1, items.count - 1); return .handled
            case .upArrow: highlighted = max((highlighted ?? items.count) - 1, 0); return .handled
            case .return, .space:
                guard let highlighted else { return .ignored }
                model.runTableMenu(items[highlighted])
                return .handled
            case .escape:
                model.rowTableMenuOpen = false
                return .handled
            default: return .ignored
            }
        }
    }
}

/// The styles' preview faces (the selection bar's style menu draws each
/// name in its style). N1 (2026-11-01) replaced Aa's dropdown list with the
/// widened pill (`NoteFormatStyleStrip`).
enum NoteFormatStyleListView {
    static func kind(_ command: NoteFormatCommand) -> AtticFormatStyleKind {
        switch command {
        case .paragraph(.heading(1)): .title
        case .paragraph(.heading(2)): .heading
        case .paragraph(.heading(3)): .subheading
        case .paragraph(.heading): .smallHeading
        case .paragraph(.mono): .mono
        default: .body
        }
    }
}

// MARK: - The / list

/// The `/` list at the caret (p2-03; E1, p2-24 D): one row per engine
/// item, icon and name, the Markdown it types quiet and trailing, and a
/// separator between its groups (Dropdown content: answers, owner,
/// 2026-10-24, answer 4 B), 224 pt wide; the typed filter emboldened. The keyboard and the pointer move the one highlight. It
/// opens below the caret when there is room, its left edge on the `/`.
struct NoteSlashListView: View {
    @ObservedObject var model: NoteSlashListModel
    @Environment(\.atticDesign) private var design

    var body: some View {
        ZStack(alignment: model.above ? .bottomLeading : .topLeading) {
            // The dropdowns' one motion, the unfold (O14-02), under the `/`.
            AtticUnfoldPresence(value: model.shown && !model.items.isEmpty ? true : nil, fromTop: !model.above) { _ in
                AtticDropdownCard(width: model.width, scrolls: model.scrolls) {
                    rows
                }
                .environment(\.atticDropdownHeight, model.viewportHeight)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(String(localized: "Insert"))
                .accessibilityIdentifier("notes-slash-list")
            }
        }
        .padding(AtticDropdownMetrics.shadowRoom)
        .fixedSize()
    }
}

extension NoteSlashListView {
    @ViewBuilder
    fileprivate var rows: some View {
        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
            if model.startsGroup(at: index) { AtticDropdownRule() }
            AtticDropdownRow(title: item.title, systemName: NoteCommandCatalog.slashSymbol(item.kind),
                             detail: NoteCommandCatalog.slashHint(item.kind), match: model.query,
                             isHighlighted: index == model.highlighted,
                             // D-18: each text style in its own size and weight,
                             // as the Aa style list shows them (unfiltered: a
                             // filter emboldens what was typed instead).
                             titleFont: model.query.isEmpty ? Self.styleFont(item.kind) : nil,
                             onHover: { inside in
                                 // The list always keeps one highlight (Return takes it).
                                 if inside, model.highlighted != index { model.highlighted = index }
                             }, position: index + 1, itemCount: model.items.count) {
                model.onPick?(item.kind)
            }
            .accessibilityIdentifier("notes-slash-\(item.kind.rawValue)")
        }
        // V-07: typing narrows the list in place. Each row keeps its own
        // identity (its kind), the rows that go are gone at once, and no
        // filtering step animates, so two lists never show together.
        .transaction(value: model.items.map(\.kind)) { $0.animation = nil }
    }

    static func styleFont(_ kind: NoteSlashItem.Kind) -> Font? {
        switch kind {
        case .title: AtticFormatStyleKind.title.font
        case .heading: AtticFormatStyleKind.heading.font
        case .subheading: AtticFormatStyleKind.subheading.font
        case .smallHeading: AtticFormatStyleKind.smallHeading.font
        default: nil
        }
    }
}

// MARK: - Date and link cards

/// The date card (owner, 2026-10-05: the shared `AtticDateCard`): typing
/// after `/date` shows one or two matching days above the month; Return
/// inserts what is lit (today when nothing is typed); a day in the month
/// inserts it; Esc puts the typed `/date` back.
struct NoteDateCardView: View {
    @ObservedObject var model: NoteFormatCardModel

    var body: some View {
        let today = model.today
        let calendar = model.calendar
        AtticDropdownCard {
            AtticDateCard(today: today, selected: nil, calendar: calendar, typed: $model.dateText,
                          parse: { NoteDateQuery.parse($0, today: today, calendar: calendar) },
                          onPick: { model.onCommitDate?($0) },
                          onCancel: { model.onCancel?() })
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Insert date"))
        .accessibilityIdentifier("notes-date-card")
    }
}

/// The link card (⇧⌘K, the link toggle, Edit Link…), with the date card's
/// field anatomy (Dropdown content: answers, owner, 2026-10-24, sheet 4):
/// the address in a 40 pt header with the link icon, ruled off, then the
/// action as a row: ↩ Add Link, or for an existing link Update Link and
/// Remove Link. Return applies; Esc cancels. 272 pt.
struct NoteLinkCardView: View {
    @ObservedObject var model: NoteFormatCardModel
    let hasLink: Bool
    @FocusState private var fieldFocused: Bool
    @Environment(\.atticDesign) private var design

    var body: some View {
        let empty = model.linkText.trimmingCharacters(in: .whitespaces).isEmpty
        let count = hasLink ? 2 : 1
        AtticDropdownCard(width: AtticNoteFormatMetrics.linkCardWidth) {
            ForEach(Array(model.linkSuggestions.enumerated()), id: \.element.id) { index, note in
                AtticDropdownRow(title: note.title, systemName: "note.text", isHighlighted: model.linkSuggestionIndex == index,
                    onHover: { if $0 { model.linkSuggestionIndex = index } }, position: index + 1, itemCount: model.linkSuggestions.count) {
                    model.chooseNote(index)
                }
                .accessibilityIdentifier("notes-link-suggestion-\(note.id)")
            }
            AtticDropdownFieldHeader {
                AtticDropdownField(text: $model.linkText, placeholder: String(localized: "Paste or type a link"), systemName: "link",
                                   focus: $fieldFocused, label: String(localized: "Link address"), identifier: "notes-link-field",
                                   onSubmit: { model.submitLink() })
                    .onExitCommand { model.onCancel?() }
            }
            if let error = model.linkError {
                AtticText(verbatim: error, style: .helper, ink: .helper)
                    .padding(.horizontal, AtticDropdownMetrics.rowPadding)
                    .padding(.top, 4)
            }
            AtticDropdownGap()
            AtticDropdownRow(title: hasLink ? String(localized: "Update Link") : String(localized: "Add Link"), systemName: "return",
                             position: 1, itemCount: count) { model.submitLink() }
                .disabled(empty)
                .accessibilityIdentifier("notes-link-apply")
            if hasLink {
                AtticDropdownRow(title: String(localized: "Remove Link"), systemName: "xmark.circle", position: 2, itemCount: count) {
                    model.onRemoveLink?()
                }
                .accessibilityIdentifier("notes-link-remove")
            }
        }
        .onAppear { fieldFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Link"))
        .accessibilityIdentifier("notes-link-card")
    }
}

/// The card on screen, if any, with the shared motion.
struct NoteFormatCardView: View {
    @ObservedObject var model: NoteFormatCardModel
    @Environment(\.atticDesign) private var design

    var body: some View {
        ZStack(alignment: model.above ? .bottomLeading : .topLeading) {
            AtticUnfoldPresence(value: model.card, fromTop: !model.above) { card in
                switch card {
                case .date:
                    NoteDateCardView(model: model).environment(\.atticDropdownHeight, model.viewportHeight)
                case let .link(hasLink):
                    NoteLinkCardView(model: model, hasLink: hasLink).environment(\.atticDropdownHeight, model.viewportHeight)
                }
            }
        }
        .environment(\.atticDropdownWidth, model.viewportWidth)
        .padding(AtticDropdownMetrics.shadowRoom)
        .fixedSize()
    }
}

/// Draft 7's hint (OD-14): "Type / for headings, lists, quotes…" on an
/// empty body line with the caret in it, faint, gone with the first
/// keystroke. Drawn only; VoiceOver hears it as the text's help.
/// The "Type /" hint, drawn by AppKit on an exact baseline (O18-04): its
/// letters stand `baselineOffset` below its top, wherever it is placed, so
/// they share the empty line's baseline with the first typed letter. The
/// same text and faces as `NoteSlashHintView`; never hit-tested or read
/// (the text view's help carries it for VoiceOver).
@MainActor
final class NoteSlashHintLabel: NSView {
    var ink: NSColor = .secondaryLabelColor { didSet { rebuild() } }
    private var line: CTLine?
    private(set) var baselineOffset: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    private func rebuild() {
        let font = AtticTextStyle.noteBody.nsFont
        let slash = NSFont.monospacedSystemFont(ofSize: font.pointSize - 0.5, weight: .regular)
        let text = NSMutableAttributedString(string: String(localized: "Type "), attributes: [.font: font, .foregroundColor: ink])
        text.append(NSAttributedString(string: "/", attributes: [.font: slash, .foregroundColor: ink]))
        text.append(NSAttributedString(string: String(localized: " for headings, lists, quotes…"), attributes: [.font: font, .foregroundColor: ink]))
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        self.line = line
        baselineOffset = ceil(ascent)
        setFrameSize(NSSize(width: ceil(width), height: baselineOffset + ceil(descent)))
        needsDisplay = true
    }

    override var fittingSize: NSSize { frame.size }

    override func draw(_ dirtyRect: NSRect) {
        guard let line, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: baselineOffset)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

struct NoteSlashHintView: View {
    static let text = String(localized: "Type / for headings, lists, quotes…")

    @Environment(\.atticDesign) private var design

    var body: some View {
        let size = AtticTextStyle.noteBody.nsFont.pointSize
        (Text(String(localized: "Type "))
            + Text(verbatim: "/").font(.system(size: size - 0.5, design: .monospaced))
            + Text(String(localized: " for headings, lists, quotes…")))
            .font(AtticTextStyle.noteBody.font)
            .foregroundStyle(design.tokens.hintInk.color)
            .fixedSize()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The existing Link field grows upward into matching note titles (B6).
struct NoteLinkSuggestionsView: View {
    @ObservedObject var model: NoteFormatCardModel
    @Environment(\.atticDesign) private var design

    var body: some View {
        let style = AtticGlassMenuStyle(design: design)
        VStack(spacing: 0) {
            ForEach(Array(model.linkSuggestions.enumerated()), id: \.element.id) { index, candidate in
                Button { model.chooseNote(index) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "note.text").font(.system(size: 10))
                        Text(verbatim: candidate.title).font(.system(size: 11)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Color(nsColor: style.title))
                    .padding(.horizontal, 9)
                    .frame(height: 23)
                    .background {
                        if model.linkSuggestionIndex == index {
                            Squircle(cornerRadius: AtticGlassMenuShape.rowRadius).fill(Color(nsColor: style.highlight))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { model.linkSuggestionIndex = index } }
                .accessibilityLabel(Text(verbatim: candidate.title))
                .accessibilityAddTraits(model.linkSuggestionIndex == index ? .isSelected : [])
                .accessibilityIdentifier("notes-link-suggestion-\(candidate.id)")
            }
        }
        .padding(.vertical, 1)
        .background(AtticGlassMenuSurface(style: style))
        .clipShape(Squircle(cornerRadius: AtticGlassMenuShape.radius))
        .padding(AtticNoteFormatMetrics.shadowRoom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Notes"))
    }
}
