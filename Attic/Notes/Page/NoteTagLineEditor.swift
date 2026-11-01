import AppKit
import SwiftUI

// MARK: - The tag line's editor (N6)

/// N6 (Adaptive picks, 2026-11-01): a note's tags are edited in the tag
/// line under its title. A click on a tag, or ⋯ → Tags…, turns the line
/// into the editor in place: the note's tags as chips with ×, then a "Find
/// or add a tag" field, then at most two lines of matches. At rest the line
/// is coloured text again (Built "Tags: coloured text, no pill"); the chips'
/// backing shows inside the editor only. It replaces the shared tag picker
/// that dropped over the note's first lines (Tasks keeps that picker).
///
/// Design px from `adaptive-drafts-notes.html` (panel N6), halved to points.
enum NoteTagLineEditorMetrics {
    /// The chips: the app's tag pill height (the draft's 34 px is 17; the
    /// app's tag text is 11.5 against the draft's 10, so its 18 tall pill).
    static let chipHeight: CGFloat = AtticControlSize.tagHeight
    /// 11 px before the name, 6 px after the ×.
    static let chipLeading: CGFloat = 5.5
    static let chipTrailing: CGFloat = 3
    /// The ×: a 22 px square.
    static let removeSize: CGFloat = 11
    static let removeGlyph: CGFloat = 7
    /// Chips and the field 8 px apart, wrapped lines 8 px apart.
    static let chipSpacing: CGFloat = 4
    static let lineSpacing: CGFloat = 4
    /// The field keeps at least 170 px; less than that left on a line and
    /// it starts the next one.
    static let fieldMinWidth: CGFloat = 85
    /// The matches: 8 px under the chips, 8 px apart, 11 px padding, the
    /// count 7 px after the name, a 1 px hairline, at most two lines.
    static let suggestionTop: CGFloat = 4
    static let suggestionSpacing: CGFloat = 4
    static let suggestionPadding: CGFloat = 5.5
    static let countGap: CGFloat = 3.5
    static let suggestionStroke: CGFloat = 0.5
    static let suggestionLines = 2
    /// The matches keep two lines' room whatever is typed, so the body
    /// moves once as the editor opens and once as it closes, never per key
    /// (audit § 8 guard rail).
    static var suggestionAreaHeight: CGFloat {
        suggestionTop + CGFloat(suggestionLines) * chipHeight + CGFloat(suggestionLines - 1) * suggestionSpacing
    }
    /// The match's count: the draft's 17 px against 20 px names.
    static let countStyle: AtticTextStyle = .taskDate
}

/// One match under the field: an existing tag the note doesn't have, with
/// how many notes carry it, or the typed name as a new tag.
struct NoteTagLineMatch: Equatable, Identifiable {
    let name: String
    let count: Int
    let isNew: Bool
    var id: String { (isNew ? "new:" : "") + name }

    /// What is typed, first: the exact tag, else the typed name as a new
    /// tag; then tags that start with it, then those that contain it (most
    /// used first). With nothing typed, every other tag, most used first.
    /// The note's own tags are never listed (they are the chips).
    static func make(query: String, counts: [String: Int], excluding: Set<String>) -> [Self] {
        let candidates = counts.filter { !excluding.contains($0.key) }
        func ranked(_ keep: (String) -> Bool) -> [Self] {
            candidates.filter { keep($0.key) }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { Self(name: $0.key, count: $0.value, isNew: false) }
        }
        guard let typed = AtticTag.normalize(query) else { return ranked { _ in true } }
        var result: [Self] = []
        if let count = candidates[typed] {
            result.append(Self(name: typed, count: count, isNew: false))
        } else if counts[typed] == nil, !excluding.contains(typed) {
            result.append(Self(name: typed, count: 0, isNew: true))
        }
        result += ranked { $0 != typed && $0.hasPrefix(typed) }
        result += ranked { !$0.hasPrefix(typed) && $0.contains(typed) }
        return result
    }

    /// What typing lights: only what was typed (the exact tag, or the new
    /// tag for it), never a prefix match, the rule the shared tag picker
    /// keeps (round 5, F5). Nothing for an empty field.
    static func typedHighlight(_ query: String, in matches: [Self]) -> String? {
        guard let typed = AtticTag.normalize(query), let first = matches.first, first.name == typed else { return nil }
        return first.id
    }

    /// The matches that fit in the editor's two lines at `width`, in order
    /// (the arrows go round these only). Unknown width: the first four.
    static func fitting(_ matches: [Self], width: CGFloat,
                        lines: Int = NoteTagLineEditorMetrics.suggestionLines) -> [Self] {
        guard width > 0 else { return Array(matches.prefix(4)) }
        let spacing = NoteTagLineEditorMetrics.suggestionSpacing
        var line = 1
        var used: CGFloat?
        var result: [Self] = []
        for match in matches {
            let itemWidth = min(match.width, width)
            if let current = used, current + spacing + itemWidth > width {
                line += 1
                guard line <= lines else { break }
                used = nil
            }
            used = used.map { $0 + spacing + itemWidth } ?? itemWidth
            result.append(match)
        }
        return result
    }

    /// The button's width as drawn (names in the tag style, the count in
    /// its own), rounded up with a point to spare for rasterising.
    var width: CGFloat {
        let m = NoteTagLineEditorMetrics.self
        func measure(_ text: String, _ style: AtticTextStyle) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: style.nsFont]).width) + 1
        }
        var width = 2 * m.suggestionPadding + measure(isNew ? Self.addTitle(name) : "#" + name, .tag)
        if !isNew { width += m.countGap + measure("\(count)", m.countStyle) }
        return width
    }

    static func addTitle(_ name: String) -> String { String(localized: "Add #\(name)") }
}

/// Where the keyboard is inside the editor: the field, a chip's ×, or a
/// match (the last two under Full Keyboard Access).
enum NoteTagLineEditorFocus: Hashable {
    case field
    case remove(String)
    case match(String)
}

/// The editor as drawn, from what it is given: the stateful editor below
/// draws it, and the tag line measures it (with no matches; the matches
/// keep a fixed room) to reserve its height under the title.
struct NoteTagLineEditorView: View {
    let tags: [String]
    @Binding var query: String
    var matches: [NoteTagLineMatch] = []
    var highlighted: String?
    var focus: FocusState<NoteTagLineEditorFocus?>.Binding?
    var onRemove: (String) -> Void = { _ in }
    var onAdd: (NoteTagLineMatch) -> Void = { _ in }
    var onKey: (KeyPress) -> KeyPress.Result = { _ in .ignored }

    @Environment(\.atticDesign) private var design

    var body: some View {
        let m = NoteTagLineEditorMetrics.self
        let motion = AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion)
        VStack(alignment: .leading, spacing: 0) {
            NoteTagChipLineLayout(spacing: m.chipSpacing, lineSpacing: m.lineSpacing, fieldMinWidth: m.fieldMinWidth) {
                ForEach(tags, id: \.self) { tag in
                    NoteTagEditChip(name: tag, focus: focus) { onRemove(tag) }
                        .transition(design.reduceMotion ? .opacity
                            : .asymmetric(insertion: .opacity.combined(with: .scale(scale: AtticMotionScale.overlayScale, anchor: .leading)),
                                          removal: .opacity.animation(AtticMotionScale.exit)))
                }
                field
            }
            .animation(motion, value: tags)
            AtticWrapLayout(spacing: m.suggestionSpacing, lineSpacing: m.suggestionSpacing) {
                ForEach(matches) { match in
                    NoteTagMatchButton(match: match, isHighlighted: match.id == highlighted, focus: focus) { onAdd(match) }
                }
            }
            .padding(.top, m.suggestionTop)
            .frame(maxWidth: .infinity, minHeight: m.suggestionAreaHeight, maxHeight: m.suggestionAreaHeight, alignment: .topLeading)
            .clipped()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Tag suggestions"))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Tags"))
        .accessibilityIdentifier("notes-tag-editor")
    }

    private var field: some View {
        let tokens = design.tokens
        let font = AtticTextStyle.rowMeta.font
        let placeholder = String(localized: "Find or add a tag")
        return TextField("", text: $query,
                         prompt: Text(verbatim: placeholder)
                            .foregroundStyle(TasksPanelDesign.toneInk(.meta, tokens: tokens).color))
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(tokens.ink(.heading).color)
            .modifier(NoteTagLineFocus(focus: focus, value: .field))
            .onKeyPress(phases: .down) { onKey($0) }
            .frame(height: NoteTagLineEditorMetrics.chipHeight)
            .accessibilityLabel(placeholder)
            .accessibilityIdentifier("notes-tag-field")
    }
}

/// `.focused` when the editor has a focus to bind (the measuring copy has none).
private struct NoteTagLineFocus: ViewModifier {
    let focus: FocusState<NoteTagLineEditorFocus?>.Binding?
    let value: NoteTagLineEditorFocus

    @ViewBuilder
    func body(content: Content) -> some View {
        if let focus { content.focused(focus, equals: value) } else { content }
    }
}

/// A tag while the line is edited: its coloured name (the line's own
/// see-through ink on glass) on a light backing, with ×.
private struct NoteTagEditChip: View {
    let name: String
    let focus: FocusState<NoteTagLineEditorFocus?>.Binding?
    let onRemove: () -> Void

    @Environment(\.atticDesign) private var design

    var body: some View {
        let m = NoteTagLineEditorMetrics.self
        let shape = RoundedRectangle(cornerRadius: AtticRadius.control(height: m.chipHeight), style: .continuous)
        HStack(spacing: 0) {
            AtticTagLabel(name: name, style: .tag, truncates: true)
                .accessibilityHidden(true)
            Button(action: onRemove) {
                AtticIcon(systemName: "xmark", size: m.removeGlyph, weight: .semibold, ink: .icon)
                    .frame(width: m.removeSize, height: m.removeSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(AtticUndimmedButtonStyle())
            .modifier(NoteTagLineFocus(focus: focus, value: .remove(name)))
            .accessibilityLabel(String(localized: "Remove #\(name)"))
            .accessibilityIdentifier("notes-tag-remove-\(name)")
        }
        .padding(.leading, m.chipLeading)
        .padding(.trailing, m.chipTrailing)
        .frame(height: m.chipHeight)
        .background(shape.fill(design.tokens.recessed.color))
        .atticTagColourMenu(name)
    }
}

/// A match: a tag in its colour and its count in a hairline capsule, or
/// "Add #name" for a new one. The keyboard's highlight and the pointer's
/// hover are the same light fill.
private struct NoteTagMatchButton: View {
    let match: NoteTagLineMatch
    let isHighlighted: Bool
    let focus: FocusState<NoteTagLineEditorFocus?>.Binding?
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticTagColouring) private var colouring
    @State private var hovered = false

    var body: some View {
        let m = NoteTagLineEditorMetrics.self
        let tokens = design.tokens
        let shape = RoundedRectangle(cornerRadius: AtticRadius.control(height: m.chipHeight), style: .continuous)
        let hue = colouring.hue(for: match.name)
        Button(action: action) {
            HStack(spacing: m.countGap) {
                if match.isNew {
                    AtticText(verbatim: NoteTagLineMatch.addTitle(match.name), style: .tag, ink: hue.ink, truncates: true)
                        .colour(TasksPanelDesign.tagInk(hue, tokens: tokens))
                } else {
                    AtticTagLabel(name: match.name, style: .tag, truncates: true)
                    AtticText(verbatim: "\(match.count)", style: m.countStyle, ink: .helper)
                        .colour(TasksPanelDesign.toneInk(.meta, tokens: tokens))
                }
            }
            .padding(.horizontal, m.suggestionPadding)
            .frame(height: m.chipHeight)
            .background(shape.fill((isHighlighted || hovered ? tokens.hover : .clear).color))
            .overlay(shape.strokeBorder(tokens.divider.color, lineWidth: m.suggestionStroke))
            .contentShape(shape)
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .onHover { hovered = $0 }
        .modifier(NoteTagLineFocus(focus: focus, value: .match(match.id)))
        .accessibilityLabel(match.isNew ? NoteTagLineMatch.addTitle(match.name)
                                        : String(localized: "Add #\(match.name), \(match.count)"))
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
        .accessibilityIdentifier("notes-tag-match-\(match.id)")
    }
}

/// The chips in lines, left to right, wrapping to the width given; the
/// last view (the field) takes the rest of its line, or the next line when
/// less than `fieldMinWidth` is left. Each line's views are centred on it.
struct NoteTagChipLineLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    var fieldMinWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let (frames, height) = arrange(width: width, subviews: subviews)
        let used = frames.map(\.maxX).max() ?? 0
        return CGSize(width: width.isFinite ? width : used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (frames, _) = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        guard !subviews.isEmpty else { return ([], 0) }
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var lines: [[Int]] = [[]]
        var x: CGFloat = 0
        for index in subviews.indices {
            let isField = index == subviews.count - 1
            let ideal = subviews[index].sizeThatFits(.unspecified)
            var itemWidth = min(ideal.width, width)
            let start = lines[lines.count - 1].isEmpty ? 0 : x + spacing
            if isField {
                let left = width - start
                if left < fieldMinWidth, !lines[lines.count - 1].isEmpty {
                    lines.append([])
                    itemWidth = width.isFinite ? width : fieldMinWidth
                    x = 0
                } else {
                    itemWidth = left.isFinite ? max(left, min(fieldMinWidth, width)) : fieldMinWidth
                    x = start
                }
            } else if !lines[lines.count - 1].isEmpty, start + itemWidth > width {
                lines.append([])
                x = 0
            } else {
                x = start
            }
            frames[index] = CGRect(x: x, y: 0, width: itemWidth, height: ideal.height)
            lines[lines.count - 1].append(index)
            x += itemWidth
        }
        var y: CGFloat = 0
        for (number, line) in lines.enumerated() {
            let height = line.map { frames[$0].height }.max() ?? 0
            for index in line { frames[index].origin.y = y + (height - frames[index].height) / 2 }
            y += height + (number == lines.count - 1 ? 0 : lineSpacing)
        }
        return (frames, y)
    }
}

/// The note's tags edited in the tag line (N6). The field has the keyboard
/// as it opens. Typing filters the matches and lights only what was typed;
/// ↓ ↑ (and → ← in an empty field) move the highlight round the matches
/// shown; Return adds the highlighted match, or closes with nothing lit;
/// Backspace in an empty field takes the last tag off; Esc closes. A click
/// in the text (the keyboard going anywhere outside the editor) closes it
/// and leaves the keyboard there. A change is an edit of the note: saved
/// with its text through the session, and an Undo step of its history.
struct NoteTagEditor: View {
    @ObservedObject var session: NoteSession
    @ObservedObject var store: NoteStore
    /// Closes the editor. `returnKeyboard`: Return or Esc, the keyboard
    /// goes back to the text; false when it already went elsewhere.
    let onClose: (_ returnKeyboard: Bool) -> Void

    @State private var revision = 0
    @State private var query = ""
    @State private var highlight: String?
    @State private var width: CGFloat = 0
    @State private var hadFocus = false
    @State private var closed = false
    @FocusState private var focus: NoteTagLineEditorFocus?

    var body: some View {
        // The engine's tags are not observable: a change bumps `revision`.
        let _ = revision
        let tags = session.engine.tags
        let shown = shownMatches(tags: tags, query: query)
        let lit = highlight.flatMap { id in shown.contains { $0.id == id } ? id : nil }
        NoteTagLineEditorView(tags: tags, query: $query, matches: shown, highlighted: lit, focus: $focus,
                              onRemove: { remove($0) }, onAdd: { add($0) },
                              onKey: { key($0, shown: shown, lit: lit) })
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onChange(of: query) { _, now in
                highlight = NoteTagLineMatch.typedHighlight(now, in: shownMatches(tags: session.engine.tags, query: now))
            }
            .onChange(of: focus) { _, now in
                if now != nil {
                    hadFocus = true
                    return
                }
                guard hadFocus else { return }
                // The keyboard left the editor (a click in the text, another
                // control): close, and leave the keyboard where it went. A
                // removed chip's × hands it back to the field in this turn.
                DispatchQueue.main.async { if focus == nil { close(returnKeyboard: false) } }
            }
            .onAppear { DispatchQueue.main.async { focus = .field } }
    }

    private func counts(_ current: [String]) -> [String: Int] {
        // The attached library supplies the same inventory as Tasks and
        // both title/composer suggestions; keep unsaved engine tags too.
        var counts = store.tagCounts
        for tag in current where counts[tag] == nil { counts[tag] = 1 }
        return counts
    }

    private func shownMatches(tags: [String], query: String) -> [NoteTagLineMatch] {
        NoteTagLineMatch.fitting(NoteTagLineMatch.make(query: query, counts: counts(tags), excluding: Set(tags)), width: width)
    }

    private func key(_ press: KeyPress, shown: [NoteTagLineMatch], lit: String?) -> KeyPress.Result {
        guard press.modifiers.subtracting([.shift, .numericPad, .function]).isEmpty else { return .ignored }
        switch press.key {
        case .return:
            if let lit, let match = shown.first(where: { $0.id == lit }) {
                add(match)
            } else if !query.isEmpty {
                // What is typed is a tag the note has already (or no tag).
                query = ""
            } else {
                close(returnKeyboard: true)
            }
            return .handled
        case .escape:
            close(returnKeyboard: true)
            return .handled
        case .downArrow:
            return step(1, in: shown, from: lit)
        case .rightArrow where query.isEmpty:
            return step(1, in: shown, from: lit)
        case .upArrow:
            return step(-1, in: shown, from: lit)
        case .leftArrow where query.isEmpty:
            return step(-1, in: shown, from: lit)
        case .delete where query.isEmpty, KeyEquivalent("\u{7F}") where query.isEmpty:
            // Backspace (the key sends U+007F; `.delete` is U+0008).
            guard let last = session.engine.tags.last else { return .ignored }
            remove(last)
            return .handled
        default:
            return .ignored
        }
    }

    private func step(_ by: Int, in shown: [NoteTagLineMatch], from lit: String?) -> KeyPress.Result {
        guard !shown.isEmpty else { return .ignored }
        let count = shown.count
        let next: Int = if let lit, let index = shown.firstIndex(where: { $0.id == lit }) {
            (index + by + count) % count
        } else {
            by > 0 ? 0 : count - 1
        }
        highlight = shown[next].id
        return .handled
    }

    private func add(_ match: NoteTagLineMatch) {
        var tags = session.engine.tags
        guard !tags.contains(match.name) else { return }
        tags.append(match.name)
        focus = .field
        session.engine.setTagsFromPicker(tags)
        query = ""
        highlight = nil
        revision += 1
    }

    private func remove(_ name: String) {
        focus = .field
        session.engine.setTagsFromPicker(session.engine.tags.filter { $0 != name })
        highlight = nil
        revision += 1
    }

    private func close(returnKeyboard: Bool) {
        guard !closed else { return }
        closed = true
        onClose(returnKeyboard)
    }
}
