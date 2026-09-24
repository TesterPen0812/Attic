import SwiftUI

// MARK: - Undo toast

/// The Undo toast: raised over content, 36 tall (radius 11.5), slides up in
/// 200 ms and stays 6 s. No pop-ups for everyday actions; this is the one
/// place an action reports back, and only for deletes and moves.
struct AtticUndoToast: View {
    let message: String
    var actionTitle: String = String(localized: "Undo")
    var onUndo: () -> Void = {}

    @State private var probeID = UUID()

    var body: some View {
        let height = AtticControlSize.toastHeight
        let radius = AtticRadius.control(height: height)
        HStack(spacing: 10) {
            AtticText(verbatim: message, style: .toast, ink: .body)
            AtticToastButton(title: actionTitle, outerRadius: radius, action: onUndo)
        }
        .padding(.leading, 14)
        .padding(.trailing, AtticControlSize.capsuleInset)
        .frame(height: height)
        .background(AtticPopoverBackground(cornerRadius: radius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
        .atticControlProbe("Toast", id: probeID, expectedSize: nil, radius: radius, expectedRadius: 11.5)
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
                .padding(.horizontal, 10)
                .frame(height: AtticControlSize.smallHeight)
                .background(RoundedRectangle(cornerRadius: inner, style: .continuous).fill((hover ? design.tokens.chipSelected : design.tokens.chipHover).color))
                .contentShape(RoundedRectangle(cornerRadius: inner, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .keyboardShortcut("z", modifiers: .command)
    }
}

// MARK: - Empty, error and loading

/// Empty: one quiet italic line where the first item would be, at the
/// row's text column. No illustrations, no big buttons.
struct AtticEmptyLine: View {
    let text: String

    var body: some View {
        AtticText(verbatim: text, style: .hint, ink: .helper)
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
    var onRetry: () -> Void = {}

    @Environment(\.atticDesign) private var design
    @Environment(\.atticForcedState) private var forced
    @State private var hovered = false

    var body: some View {
        let hover = forced == .hover || hovered
        HStack(spacing: 5) {
            AtticIcon(systemName: "exclamationmark.circle", size: 12, weight: .medium, ink: .warningText)
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
        .frame(height: 22)
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
                HStack(spacing: 0) {
                    Circle().fill(fill).frame(width: 14, height: 14)
                        .padding(.leading, AtticLayout.circleX + 1)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(fill)
                        .frame(width: [148, 112, 176, 132][index % 4], height: 10)
                        .padding(.leading, AtticLayout.textX - AtticLayout.circleX - 15)
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
                .trim(from: 0, to: 0.72)
                .stroke(design.tokens.color(.icon), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(-90))
        } else {
            ProgressView().controlSize(.small).scaleEffect(0.8)
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
            shape.strokeBorder(tokens.focusRing.color, lineWidth: 1.5)
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
        ZStack(alignment: .topTrailing) {
            ZStack {
                if count > 2 { card.rotationEffect(.degrees(3.5)).offset(x: 5, y: 3).opacity(0.9) }
                if count > 1 { card.rotationEffect(.degrees(0.5)).offset(x: 2.5, y: 1.5) }
                card.rotationEffect(.degrees(-3))
            }
            if count > 1 {
                AtticText(verbatim: "\(count)", style: .tag, ink: .onInverse, allowsOverlap: true)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(design.tokens.color(.inverseFill)))
                    .offset(x: 8, y: -8)
                    .accessibilityLabel(String(localized: "\(count) items"))
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var card: some View {
        let tokens = design.tokens
        let shape = RoundedRectangle(cornerRadius: AtticRadius.tile, style: .continuous)
        Group {
            switch item {
            case let .task(title, state, priority):
                HStack(spacing: 8) {
                    AtticStatusCircle(state: state, priority: priority)
                    AtticText(verbatim: title, style: .rowTitle, ink: .body, allowsOverlap: true)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .frame(maxWidth: 200, alignment: .leading)
                .fixedSize()
            case let .file(name):
                VStack(spacing: 5) {
                    AtticThumbnailPlaceholder()
                        .frame(width: 72, height: 50)
                    AtticText(verbatim: name, style: .rowMeta, ink: .helper, allowsOverlap: true)
                        .frame(maxWidth: 88)
                }
                .padding(8)
            }
        }
        .background {
            ZStack {
                AtticOutsideShadow(shape: shape, color: tokens.dragShadow, radius: 10, y: 6)
                shape.fill(tokens.popoverFill.color)
                shape.inset(by: 0.5).stroke(tokens.popoverInnerRim.color, lineWidth: 1)
                shape.stroke(tokens.popoverOuterRim.color, lineWidth: 0.5)
            }
        }
    }
}

/// An image stand-in for thumbnails (radius 8, the image radius).
struct AtticThumbnailPlaceholder: View {
    @Environment(\.atticDesign) private var design

    var body: some View {
        let dark = design.mode == .dark
        RoundedRectangle(cornerRadius: AtticRadius.image, style: .continuous)
            .fill(LinearGradient(
                colors: dark
                    ? [Color(.sRGB, red: 0.30, green: 0.34, blue: 0.42), Color(.sRGB, red: 0.22, green: 0.24, blue: 0.30)]
                    : [Color(.sRGB, red: 0.80, green: 0.85, blue: 0.93), Color(.sRGB, red: 0.90, green: 0.92, blue: 0.96)],
                startPoint: .top, endPoint: .bottom
            ))
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.white.opacity(dark ? 0.25 : 0.8))
                    .frame(width: 38, height: 5)
                    .padding(7)
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
                    AtticOutsideShadow(shape: shape, color: tokens.dragShadow.withAlpha(tokens.dragShadow.alpha * 0.8), radius: 8, y: 3)
                    shape.fill(tokens.popoverFill.color)
                    shape.inset(by: 0.5).stroke(tokens.popoverInnerRim.color, lineWidth: 1)
                    shape.stroke(tokens.popoverOuterRim.color, lineWidth: 0.5)
                }
                .padding(.horizontal, AtticLayout.rowHighlightInset)
                .padding(.vertical, 1)
            }
    }
}
