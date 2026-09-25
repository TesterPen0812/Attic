import SwiftUI

// MARK: - Undo toast

/// The Undo toast: raised over content, 36 tall (radius 15), slides up in
/// 200 ms and stays 6 s. No pop-ups for everyday actions; this is the one
/// place an action reports back, and only for deletes and moves.
struct AtticUndoToast: View {
    let message: String
    var actionTitle: String = String(localized: "Undo")
    let onUndo: () -> Void

    @State private var probeID = UUID()

    var body: some View {
        let height = AtticControlSize.toastHeight
        let radius = AtticRadius.control(height: height)
        HStack(spacing: AtticToastMetrics.gap) {
            AtticText(verbatim: message, style: .toast, ink: .body)
            AtticToastButton(title: actionTitle, outerRadius: radius, action: onUndo)
        }
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
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @State private var hovered = false

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
        .onHover { hovered = $0 }
        .keyboardShortcut("z", modifiers: .command)
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

/// Empty: one quiet italic line where the first item would be, at the
/// row's text column. No illustrations, no big buttons.
struct AtticEmptyLine: View {
    let text: String
    /// A footnote under a list ("Done tasks move to Done tomorrow") is
    /// quieter still: the row meta size, upright (v9).
    var isFootnote = false

    var body: some View {
        AtticText(verbatim: text, style: isFootnote ? .rowMeta : .hint, ink: .helper)
            .frame(height: AtticLayout.rowPitch)
            .padding(.leading, AtticLayout.textX)
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
                    AtticStatusCircle(state: state, priority: priority)
                    AtticText(verbatim: title, style: .rowTitle, ink: .body, allowsOverlap: true)
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
