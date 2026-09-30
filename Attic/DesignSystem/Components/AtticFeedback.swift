import SwiftUI

// MARK: - Undo toast

/// What holds a toast on screen past its 6 s (Astra 23): the pointer on
/// it, its button's keyboard focus, or VoiceOver on it.
enum AtticToastHold: Hashable {
    case pointer, keyboard, accessibility
}

/// The Undo toast: raised over content, 36 tall (radius 15), slides up in
/// 200 ms and stays 6 s. No pop-ups for everyday actions; this is the one
/// place an action reports back, and only for deletes and moves.
///
/// Its button has no shortcut of its own (Astra 23): ⌘Z goes to the text
/// being edited first, then to the page's history, which the toast's step
/// is the top of. A failed action keeps the toast, in the warning colour,
/// with its reason. The pointer, the button's keyboard focus and VoiceOver
/// each hold it open (`onHold`).
struct AtticUndoToast: View {
    let message: String
    var actionTitle: String = String(localized: "Undo")
    /// The action failed: the message is its reason (warning ink).
    var isFailure = false
    /// Keyboard focus or VoiceOver arrived on the toast (true) or left.
    var onHold: (AtticToastHold, Bool) -> Void = { _, _ in }
    let onUndo: () -> Void

    @State private var probeID = UUID()
    @AccessibilityFocusState private var voiceOverOnMessage: Bool
    @AccessibilityFocusState private var voiceOverOnButton: Bool

    var body: some View {
        let height = AtticControlSize.toastHeight
        let radius = AtticRadius.control(height: height)
        HStack(spacing: AtticToastMetrics.gap) {
            AtticText(verbatim: message, style: .toast, ink: isFailure ? .warningText : .body)
                .accessibilityFocused($voiceOverOnMessage)
            AtticToastButton(title: actionTitle, outerRadius: radius, onFocus: { onHold(.keyboard, $0) }, action: onUndo)
                .accessibilityFocused($voiceOverOnButton)
        }
        .onChange(of: voiceOverOnMessage || voiceOverOnButton) { _, focused in onHold(.accessibility, focused) }
        .padding(.leading, AtticToastMetrics.leadingPadding)
        .padding(.trailing, AtticControlSize.capsuleInset)
        .frame(height: height)
        .background(AtticPopoverBackground(cornerRadius: radius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
        .atticControlProbe("Toast", id: probeID, expectedSize: nil, radius: radius, expectedRadius: 15)
    }
}

private struct AtticToastButton: View {
    let title: String
    let outerRadius: CGFloat
    var onFocus: (Bool) -> Void = { _ in }
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        let inner = AtticRadius.nested(outer: outerRadius, gap: AtticControlSize.capsuleInset) ?? outerRadius
        let hover = forced == .hover || hovered
        Button(action: action) {
            AtticText(verbatim: title, style: .controlLabel, ink: .heading)
                .padding(.horizontal, AtticToastMetrics.buttonPadding)
                .frame(height: AtticControlSize.smallHeight)
                .background(RoundedRectangle(cornerRadius: inner, style: .continuous).fill((hover ? design.tokens.chipSelected : design.tokens.chipHover).color))
                .contentShape(RoundedRectangle(cornerRadius: inner, style: .continuous))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onChange(of: focused) { _, now in onFocus(now) }
        .onHover { hovered = $0 }
    }
}

// MARK: - Notice

/// A problem that concerns the whole panel (a failed save, an import that
/// could not finish): raised over content like the toast, in the warning
/// colour, with the next step as a button. It stays until it is resolved or
/// dismissed; a problem is never hidden. The message is the store's own
/// sentence, so it may take two lines (the only wrapping panel text), and
/// the full text is its tooltip and VoiceOver label.
struct AtticNotice: View {
    let message: String
    /// "Retry" when the failed step can run again; nil offers only Dismiss.
    var actionTitle: String?
    var onAction: (() -> Void)?
    let onDismiss: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var probeID = UUID()

    var body: some View {
        let tokens = design.tokens
        let radius = AtticRadius.control(height: AtticControlSize.toastHeight)
        HStack(alignment: .center, spacing: AtticNoticeMetrics.gap) {
            AtticIcon(systemName: "exclamationmark.circle", size: AtticErrorLineMetrics.iconSize, weight: .medium, ink: .warningText)
            Text(verbatim: message)
                .font(AtticTextStyle.toast.font)
                .foregroundStyle(tokens.ink(.warningText).color)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(message)
            if let actionTitle, let onAction {
                AtticNoticeButton(title: actionTitle, outerRadius: radius, action: onAction)
            }
            AtticSmallButton(systemName: "xmark", label: "Dismiss", action: onDismiss)
                .accessibilityIdentifier("panel-error-dismiss")
        }
        .padding(.leading, AtticToastMetrics.leadingPadding)
        .padding(.trailing, AtticControlSize.capsuleInset)
        .padding(.vertical, AtticControlSize.capsuleInset)
        .frame(minHeight: AtticControlSize.toastHeight)
        .background(AtticPopoverBackground(cornerRadius: radius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
        .atticControlProbe("Notice", id: probeID, expectedSize: nil, radius: radius, expectedRadius: 15)
    }
}

private struct AtticNoticeButton: View {
    let title: String
    let outerRadius: CGFloat
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @State private var hovered = false

    var body: some View {
        let inner = AtticRadius.nested(outer: outerRadius, gap: AtticControlSize.capsuleInset) ?? outerRadius
        let hover = forced == .hover || hovered
        Button(action: action) {
            AtticText(verbatim: title, style: .controlLabel, ink: .warningText)
                .padding(.horizontal, AtticToastMetrics.buttonPadding)
                .frame(height: AtticControlSize.smallHeight)
                .background(RoundedRectangle(cornerRadius: inner, style: .continuous).fill((hover ? design.tokens.chipSelected : design.tokens.chipHover).color))
                .contentShape(RoundedRectangle(cornerRadius: inner, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
    }
}

// MARK: - Empty, error and loading

/// Empty: one quiet line where the first item would be, on the row's
/// title line (Direction A: upright 13 pt, the secondary grey, no
/// italics). No illustrations, no big buttons.
struct AtticEmptyLine: View {
    let text: String

    var body: some View {
        AtticText(verbatim: text, style: .listBody, ink: .helper)
            .frame(height: AtticTaskRowMetrics.titleLineHeight)
            .padding(.top, AtticTaskRowMetrics.titleTop(twoLine: false))
            .padding(.bottom, AtticLayout.rowPitch - AtticTaskRowMetrics.titleTop(twoLine: false) - AtticTaskRowMetrics.titleLineHeight)
            // On the tab labels' line (x 28; owner, 2026-09-26).
            .padding(.leading, AtticLayout.pageTabsX)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A problem is never hidden: "Not saved · Retry" in the warning colour,
/// shown in place of the quiet state, with the next step as a button.
struct AtticErrorLine: View {
    let message: String
    var actionTitle: String = String(localized: "Retry")
    let onRetry: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @State private var hovered = false

    var body: some View {
        let hover = forced == .hover || hovered
        HStack(spacing: AtticErrorLineMetrics.gap) {
            AtticIcon(systemName: "exclamationmark.circle", size: AtticErrorLineMetrics.iconSize, weight: .medium, ink: .warningText)
            AtticText(verbatim: message, style: .controlLabel, ink: .warningText)
            AtticText(verbatim: "·", style: .controlLabel, ink: .warningText)
            Button(action: onRetry) {
                AtticText(verbatim: actionTitle, style: .controlLabel, ink: .warningText)
                    .underline(hover, color: design.tokens.color(.warningText))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
        }
        .frame(height: AtticErrorLineMetrics.height)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .accessibilityAction(named: Text(actionTitle), onRetry)
    }
}

/// Loading: static skeleton rows (8 % bars, radius 4) that fade in only if
/// loading takes long enough to notice. No shimmer, no looping motion.
struct AtticLoadingRows: View {
    var count = 3

    @Environment(\.atticDesign) private var design

    var body: some View {
        let fill = design.tokens.skeleton.color
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                let m = AtticSkeletonMetrics.self
                let circleLeading = AtticLayout.circleX + (AtticControlSize.statusCircle - m.circle) / 2
                HStack(spacing: 0) {
                    Circle().fill(fill).frame(width: m.circle, height: m.circle)
                        .padding(.leading, circleLeading)
                    RoundedRectangle(cornerRadius: m.barRadius, style: .continuous)
                        .fill(fill)
                        .frame(width: m.barWidths[index % m.barWidths.count], height: m.barHeight)
                        .padding(.leading, AtticLayout.textX - circleLeading - m.circle)
                    Spacer(minLength: 0)
                }
                .frame(height: AtticLayout.rowPitch)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Loading"))
    }
}

/// A control that is working shows a small spinner in place of its glyph,
/// keeping its size. The system spinner (native first); a static arc in
/// captures, where AppKit views cannot be drawn.
struct AtticSpinner: View {
    @Environment(\.atticCapture) private var capture
    @Environment(\.atticDesign) private var design

    var body: some View {
        if capture != nil {
            Circle()
                .trim(from: 0, to: AtticSpinnerMetrics.arc)
                .stroke(design.tokens.color(.icon), style: StrokeStyle(lineWidth: AtticSpinnerMetrics.lineWidth, lineCap: .round))
                .frame(width: AtticSpinnerMetrics.size, height: AtticSpinnerMetrics.size)
                .rotationEffect(.degrees(-90))
        } else {
            ProgressView().controlSize(.small).scaleEffect(AtticSpinnerMetrics.systemScale)
        }
    }
}

// MARK: - Drag and drop

/// The drop target: the selection shape outlined in the accent (2 pt ring
/// inside, over a hover fill). It says what will happen only when that is
/// not obvious ("Add to page", "Attach to task"); the label is the row's.
struct AtticDropOutline: View {
    var cornerRadius: CGFloat = AtticRadius.highlight

    @Environment(\.atticDesign) private var design

    var body: some View {
        let tokens = design.tokens
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(tokens.hover.color)
            shape.strokeBorder(tokens.focusRing.color, lineWidth: AtticRingMetrics.dropOutlineWidth)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// What a carry drag holds.
enum AtticCarryItem: Sendable {
    case task(title: String, state: AtticTaskState, priority: AtticPriority)
    case file(name: String)
}

/// Carry: the item lifts as a small tilted card with a soft shadow (a
/// thumbnail and the name for files and images, the circle and title for
/// tasks); several items form a neat stack with a count. The tilt is static.
struct AtticCarryPreview: View {
    let item: AtticCarryItem
    var count = 1

    @Environment(\.atticDesign) private var design

    var body: some View {
        let m = AtticDragMetrics.self
        ZStack(alignment: .topTrailing) {
            ZStack {
                if count > 2 {
                    card.rotationEffect(.degrees(m.stackTilts[1])).offset(m.stackOffsets[1]).opacity(m.stackBackOpacity)
                }
                if count > 1 { card.rotationEffect(.degrees(m.stackTilts[0])).offset(m.stackOffsets[0]) }
                card.rotationEffect(.degrees(m.tilt))
            }
            if count > 1 {
                AtticText(verbatim: "\(count)", style: .tag, ink: .onInverse, allowsOverlap: true)
                    .padding(.horizontal, m.badgePadding)
                    .frame(minWidth: m.badgeSize, minHeight: m.badgeSize)
                    .background(Capsule().fill(design.tokens.color(.inverseFill)))
                    .offset(x: m.badgeOffset, y: -m.badgeOffset)
                    .accessibilityLabel(String(localized: "\(count) items"))
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var card: some View {
        let tokens = design.tokens
        let m = AtticDragMetrics.self
        let shape = RoundedRectangle(cornerRadius: AtticRadius.tile, style: .continuous)
        Group {
            switch item {
            case let .task(title, state, priority):
                HStack(spacing: m.taskCardGap) {
                    AtticStatusCircle(state: state)
                    AtticText(verbatim: title, style: .rowTitle, ink: .body, allowsOverlap: true)
                    if state != .done { AtticPriorityMark(priority: priority) }
                }
                .padding(.horizontal, m.taskCardPadding)
                .frame(height: m.taskCardHeight)
                .frame(maxWidth: m.taskCardMaxWidth, alignment: .leading)
                .fixedSize()
            case let .file(name):
                VStack(spacing: m.fileCardGap) {
                    AtticThumbnailPlaceholder()
                        .frame(width: m.thumbnailSize.width, height: m.thumbnailSize.height)
                    AtticText(verbatim: name, style: .rowMeta, ink: .helper, allowsOverlap: true)
                        .frame(maxWidth: m.fileNameMaxWidth)
                }
                .padding(m.fileCardPadding)
            }
        }
        .background {
            ZStack {
                AtticOutsideShadow(shape: shape, color: tokens.dragShadow, spec: AtticShadows.carry)
                shape.fill(tokens.popoverFill.color)
                shape.inset(by: AtticHairline.innerRim / 2).stroke(tokens.popoverInnerRim.color, lineWidth: AtticHairline.innerRim)
                shape.stroke(tokens.popoverOuterRim.color, lineWidth: AtticHairline.width)
            }
        }
    }
}

/// An image stand-in for thumbnails (radius 8, the image radius).
struct AtticThumbnailPlaceholder: View {
    @Environment(\.atticDesign) private var design

    var body: some View {
        let t = AtticThumbnailTokens.self
        let dark = design.mode == .dark
        let gradient = dark ? t.darkGradient : t.lightGradient
        RoundedRectangle(cornerRadius: AtticRadius.image, style: .continuous)
            .fill(LinearGradient(colors: [gradient.top.color, gradient.bottom.color], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: t.barRadius, style: .continuous)
                    .fill((dark ? t.barDark : t.barLight).color)
                    .frame(width: t.barSize.width, height: t.barSize.height)
                    .padding(t.barInset)
            }
            .accessibilityHidden(true)
    }
}

/// Reorder: the row lifts straight up in place (raised, soft shadow, no
/// tilt) while the others slide apart to make room.
struct AtticReorderLift<Content: View>: View {
    @ViewBuilder let content: Content

    @Environment(\.atticDesign) private var design

    var body: some View {
        let tokens = design.tokens
        let shape = RoundedRectangle(cornerRadius: AtticRadius.highlight, style: .continuous)
        content
            .background {
                ZStack {
                    AtticOutsideShadow(shape: shape, color: tokens.dragShadow, spec: AtticShadows.reorder)
                    shape.fill(tokens.popoverFill.color)
                    shape.inset(by: AtticHairline.innerRim / 2).stroke(tokens.popoverInnerRim.color, lineWidth: AtticHairline.innerRim)
                    shape.stroke(tokens.popoverOuterRim.color, lineWidth: AtticHairline.width)
                }
                .padding(.horizontal, AtticLayout.rowHighlightInset)
                .padding(.vertical, AtticTaskRowMetrics.pitchTopInset)
            }
    }
}

// MARK: - Status slot (Phase 2, Notes)

/// One state in the Notes status slot (UX plan § 3.12): its glyph, label,
/// why, and what can be done. The slot's pill shows the most urgent; the
/// details pop-over lists every one.
struct AtticStatusItem: Identifiable {
    enum Tone: Equatable { case warning, normal, quiet }
    struct Action: Identifiable {
        let title: String
        var identifier: String?
        let handler: () -> Void
        var id: String { title }
    }

    let id: String
    /// nil shows the small spinner (work in progress).
    let systemName: String?
    let title: String
    var explanation: String?
    var tone: Tone = .normal
    var actions: [Action] = []
}

/// The status slot's pill between the Notes bottom buttons (p2-05, p2-15):
/// a raised capsule, 36 tall, at most 176 wide, with the most urgent
/// state's glyph and label (the warning colour for a problem), then the
/// state's inline action ("Retry"), or "+N" when there is more, or ✕ for a
/// batch that can be cancelled. A click, Return or VoiceOver opens the
/// details; nothing needs hover.
struct AtticStatusPill: View {
    let item: AtticStatusItem
    /// How many more states the details list.
    var more = 0
    /// Shown as a chip inside the pill (only when there is nothing more).
    var inlineAction: AtticStatusItem.Action?
    /// ✕ inside the pill (an import).
    var onCancel: (() -> Void)?
    let onOpen: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var probeID = UUID()

    var body: some View {
        let m = AtticNoteMetrics.self
        let radius = AtticRadius.control(height: m.pillHeight)
        // A quiet state (Read only) is said by its glyph; its words keep the
        // body ink, since the secondary grey falls under 3 : 1 on raised
        // material in some Dark palettes (the appearance matrix).
        let ink: AtticInk = item.tone == .warning ? .warningText : .body
        HStack(spacing: m.pillGap) {
            Button(action: onOpen) {
                HStack(spacing: m.pillGap) {
                    if let systemName = item.systemName {
                        AtticIcon(systemName: systemName, size: m.pillIconSize, weight: .medium,
                                  ink: item.tone == .warning ? .warningText : .icon)
                    } else {
                        AtticSpinner()
                    }
                    AtticText(verbatim: item.title, style: .toast, ink: ink, truncates: true)
                    if more > 0 {
                        AtticText(verbatim: "+\(more)", style: .count, ink: .body)
                            .padding(.horizontal, AtticTagMetrics.horizontalPadding)
                            .frame(height: AtticControlSize.tagHeight)
                            .background(RoundedRectangle(cornerRadius: AtticRadius.control(height: AtticControlSize.tagHeight), style: .continuous)
                                .fill(design.tokens.chipHover.color))
                    }
                }
                .frame(height: m.pillHeight)
                .padding(.leading, m.pillPadding)
                .padding(.trailing, inlineAction == nil && onCancel == nil ? m.pillPadding : 0)
                .contentShape(Rectangle())
            }
            .buttonStyle(AtticUndimmedButtonStyle())
            .focusEffectDisabled()
            .accessibilityLabel(more > 0 ? String(localized: "\(item.title), and \(more) more") : item.title)
            .accessibilityHint(String(localized: "Shows details"))
            .accessibilityIdentifier("notes-status-primary")
            if let inlineAction {
                AtticToastButton(title: inlineAction.title, outerRadius: radius, action: inlineAction.handler)
                    .accessibilityIdentifier(inlineAction.identifier ?? "notes-status-action")
            } else if let onCancel {
                AtticSmallButton(systemName: "xmark", label: "Cancel", action: onCancel)
                    .accessibilityIdentifier("notes-status-cancel")
            }
        }
        .padding(.trailing, inlineAction == nil && onCancel == nil ? 0 : AtticControlSize.capsuleInset)
        .frame(maxWidth: m.pillMaxWidth)
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: m.pillHeight)
        .atticRaisedMaterial(cornerRadius: radius, interactive: false)
        .accessibilityElement(children: .contain)
        .atticControlProbe("Status pill", id: probeID, expectedSize: nil, radius: radius, expectedRadius: 15)
    }
}

/// The slot's details (p2-15 #2): every state with why and what to do, the
/// first action as a button, the others quieter; hairlines between states.
struct AtticStatusDetails: View {
    let items: [AtticStatusItem]

    @Environment(\.atticDesign) private var design

    var body: some View {
        let m = AtticNoteMetrics.self
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle().fill(design.tokens.divider.color).frame(height: AtticHairline.width)
                        .padding(.vertical, m.detailsItemGap / 2)
                }
                HStack(alignment: .firstTextBaseline, spacing: m.pillGap + 2) {
                    Group {
                        if let systemName = item.systemName {
                            AtticIcon(systemName: systemName, size: m.pillIconSize, weight: .medium,
                                      ink: item.tone == .warning ? .warningText : .icon)
                        } else {
                            AtticSpinner()
                        }
                    }
                    .frame(width: 16)
                    VStack(alignment: .leading, spacing: 4) {
                        AtticText(verbatim: item.title, style: .panelHeading, ink: item.tone == .warning ? .warningText : .heading)
                        if let explanation = item.explanation {
                            Text(verbatim: explanation)
                                .font(AtticTextStyle.settingsHelper.font)
                                .foregroundStyle(design.tokens.color(.helper))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !item.actions.isEmpty {
                            // One row when the actions fit the popover; the
                            // rest go under the first two when they do not.
                            ViewThatFits(in: .horizontal) {
                                actionRow(item.actions, offset: 0)
                                VStack(alignment: .leading, spacing: 2) {
                                    actionRow(Array(item.actions.prefix(2)), offset: 0)
                                    actionRow(Array(item.actions.dropFirst(2)), offset: 2)
                                }
                            }
                            .padding(.top, 6)
                            .padding(.leading, -AtticToastMetrics.buttonPadding)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
        .padding(m.detailsPadding)
        .frame(width: m.detailsWidth, alignment: .leading)
        .accessibilityIdentifier("notes-status-details")
    }

    private func actionRow(_ actions: [AtticStatusItem.Action], offset: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                AtticStatusDetailButton(title: action.title, prominent: index + offset == 0, action: action.handler)
                    .accessibilityIdentifier(action.identifier ?? "")
            }
        }
    }
}

private struct AtticStatusDetailButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var hovered = false

    var body: some View {
        let height = AtticControlSize.smallHeight
        let radius = AtticRadius.control(height: height)
        let fill: AtticRGBA = prominent ? (hovered ? design.tokens.chipSelected : design.tokens.chipHover)
            : (hovered ? design.tokens.chipHover : .clear)
        Button(action: action) {
            AtticText(verbatim: title, style: .controlLabel, ink: prominent ? .heading : .body)
                .padding(.horizontal, AtticToastMetrics.buttonPadding)
                .frame(height: height)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill.color))
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(AtticUndimmedButtonStyle())
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
    }
}

/// The reorder lift as a modifier (owner fix 6): the row keeps one view
/// identity whether lifted or not, so a drag in progress is never torn
/// down by the lift appearing (the stuck lift the owner saw).
struct AtticReorderLiftModifier: ViewModifier {
    let lifted: Bool

    @Environment(\.atticDesign) private var design

    func body(content: Content) -> some View {
        let tokens = design.tokens
        let shape = RoundedRectangle(cornerRadius: AtticRadius.highlight, style: .continuous)
        content
            .background {
                // Only the background changes: `content` keeps its identity.
                if lifted {
                ZStack {
                    AtticOutsideShadow(shape: shape, color: tokens.dragShadow, spec: AtticShadows.reorder)
                    shape.fill(tokens.popoverFill.color)
                    shape.inset(by: AtticHairline.innerRim / 2).stroke(tokens.popoverInnerRim.color, lineWidth: AtticHairline.innerRim)
                    shape.stroke(tokens.popoverOuterRim.color, lineWidth: AtticHairline.width)
                }
                .padding(.horizontal, AtticLayout.rowHighlightInset)
                .padding(.vertical, AtticTaskRowMetrics.pitchTopInset)
                }
            }
    }
}
