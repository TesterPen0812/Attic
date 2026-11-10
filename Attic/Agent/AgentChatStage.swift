import AppKit
import Combine
import SwiftUI

/// The ✦ in the bar. Closed, it says what the run is doing, as plain states.
struct AgentChatBarButton: View {
    @ObservedObject var bar: AgentChatBar
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var hovered = false

    var body: some View {
        let label = bar.state.label
        Button(action: action) {
            HStack(spacing: 5) {
                glyph(labelled: label != nil)
                    .frame(width: 11, height: 11)
                    .rotationEffect(.degrees(hovered && !design.reduceMotion ? 90 : 0))
                    .scaleEffect(hovered && !design.reduceMotion ? 1.14 : 1)
                    .animation(.timingCurve(0.3, 1.7, 0.5, 1, duration: 0.46), value: hovered)
                if let label {
                    Text(label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(design.tokens.ink(.heading).color)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, label == nil ? 0 : 8)
            .frame(minWidth: AtticControlSize.headerControl)
            .frame(height: AtticControlSize.headerControl)
            .contentShape(Rectangle())
        }
        .buttonStyle(AtticRaisedButtonStyle(cornerRadius: AtticRadius.header, flat: design.effectiveControls != .liquidGlass))
        .atticDesignCorners()
        .onHover { hovered = $0 }
        .animation(AtticMotionPreset.popover.animation(reduceMotion: design.reduceMotion, showing: true), value: label)
        .help(String(localized: "Chat"))
        .accessibilityLabel(label ?? String(localized: "Chat"))
        .accessibilityIdentifier("agent-chat-button")
    }

    @ViewBuilder
    private func glyph(labelled: Bool) -> some View {
        if labelled {
            AgentSparkShape().fill(LinearGradient(gradient: AgentIris.underline, startPoint: .leading, endPoint: .trailing))
        } else {
            AgentSparkShape().fill(design.tokens.ink(.heading).color)
        }
    }
}

/// Puts the chat over the panel while it is open or closing, and nothing at
/// all otherwise: a closed chat is one `if`, however busy its run is.
struct AgentChatHost: View {
    @ObservedObject var bar: AgentChatBar
    @ObservedObject var room: PanelComposerRoom
    let model: AgentChatModel
    let layout: PanelPageLayout
    let page: PanelPage
    let chrome: PanelSharedChrome
    /// Rows on the Tasks page, by id (nil: all), in the window's coordinates.
    let rows: (Set<UUID>?) -> [(id: UUID, frame: CGRect)]
    let selectPage: (PanelPage) -> Void
    let setTyping: (Bool) -> Void

    @Environment(\.panelTopRowState) private var topRow
    @State private var mounted = false
    /// Held here so Undo can still run a step's motion after a close and reopen.
    @StateObject private var fx = AgentChatFX()
    #if DEBUG
    /// Test seam: the alive layer of the host on screen.
    static var lastFX: AgentChatFX?
    #endif

    var body: some View {
        #if DEBUG
        let _ = Self.lastFX = fx
        #endif
        ZStack {
            if mounted {
                AgentChatStage(model: model, fx: fx, shown: bar.isChatOpen, layout: layout, rows: rows, setTyping: setTyping,
                               didClose: { if !bar.isChatOpen { mounted = false } })
            }
        }
        .onAppear { model.openPage = { [selectPage] in selectPage($0.panelPage) } }
        .onChange(of: bar.isChatOpen, initial: true) { _, open in
            if chrome.plusHandedOver != open, !room.isOpen { chrome.plusHandedOver = open }
            if topRow?.chatOver != open { topRow?.chatOver = open }
            if open {
                mounted = true
            } else if model.closedAtOnce {
                mounted = false
                setTyping(false)
            }
        }
        .onDisappear { if topRow?.chatOver == true { topRow?.chatOver = false } }
        .onChange(of: page) { _, now in model.pageChanged(to: AgentPage(now)) }
        .onChange(of: room.isOpen) { _, open in if open { model.close() } }
    }
}

/// The floating chat: the blur, the thread on it, the composer in the bar's
/// place, and the alive layer over everything.
struct AgentChatStage: View {
    static let space = "AgentChatStage"

    @ObservedObject var model: AgentChatModel
    let fx: AgentChatFX
    let shown: Bool
    let layout: PanelPageLayout
    let rows: (Set<UUID>?) -> [(id: UUID, frame: CGRect)]
    let setTyping: (Bool) -> Void
    let didClose: () -> Void

    #if DEBUG
    /// Test seams: how often the stage's body ran, whether it is on screen, and
    /// the strip each move's chips flew to.
    static var bodyEvaluations = 0
    static var isMounted = false
    static var chipFlights: [UUID] = []
    #endif

    @Environment(\.atticDesign) private var design
    @State private var backdropView: AgentChatBackdropView?
    /// The wipe's progress, 0 to 1: the one clock the blur, its colour and
    /// the thread share. It starts at 0 and animates on the wipe's curve.
    @State private var reveal: CGFloat = 0

    private var alive: Bool { !design.reduceMotion }
    private var dark: Bool { design.tokens.context.mode == .dark }
    private var solid: Bool { design.tokens.context.reducedFrom != nil || AtticVariableBlurView.backdropClass == nil }

    /// The ✦'s centre: where the blur opens from.
    private var star: CGPoint {
        let insets = PanelSharedBottomBar.plusInsets(layout: layout)
        let side = AtticControlSize.headerControl
        return CGPoint(x: layout.panelSize.width - insets.trailing - side - TasksDesignMetrics.footerGap - side / 2,
                       y: layout.panelSize.height - insets.bottom - side / 2)
    }

    private var tint: NSColor {
        let alpha: CGFloat = solid ? 0.9 : dark ? 0.3 : 0.24
        return dark ? NSColor(white: 0.11, alpha: alpha) : NSColor(red: 243 / 255, green: 243 / 255, blue: 244 / 255, alpha: alpha)
    }

    var body: some View {
        #if DEBUG
        let _ = Self.bodyEvaluations += 1
        #endif
        ZStack(alignment: .topTrailing) {
            AgentChatBackdrop(shown: shown, reveal: reveal, origin: star, tint: tint, fades: !alive, solid: solid,
                              onEscape: { model.close() },
                              didMake: { view in DispatchQueue.main.async { backdropView = view } })
                .overlay { Color.clear.contentShape(Rectangle()).onTapGesture { model.close() } }
                .accessibilityHidden(true)
            if alive {
                // Only the fade is eased here: the circle keeps the wipe's curve.
                AgentChatAuraLayer(fx: fx, reveal: reveal).animation(.easeOut(duration: 0.3)) { $0.opacity(shown ? 1 : 0) }
            }
            VStack(spacing: 0) {
                PanelControlFold(folded: !shown, animation: { _ in .easeOut(duration: 0.2) }) {
                    if model.entries.isEmpty {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { model.close() }
                    } else {
                        AgentChatThread(model: model, fx: fx, alive: alive, onAway: { model.close() })
                    }
                }
                // The thread arrives with the blur under it, never over the
                // page's still readable rows (screen 9): the wipe's circle,
                // or its fade.
                .modifier(AgentChatWipeReveal(reveal: reveal, wipe: AgentChatWipe(origin: star, size: layout.panelSize), fades: !alive))
                AgentChatComposer(model: model, fx: fx, shown: shown, layout: layout, alive: alive, setTyping: setTyping, didClose: didClose)
            }
            if !model.entries.isEmpty {
                PanelControlFold(folded: !shown, animation: { _ in .easeOut(duration: 0.2) }) { topControls }
                    .padding(.top, layout.chromeInsets.top)
                    .padding(.trailing, PanelSharedBottomBar.plusInsets(layout: layout).trailing)
                    .transition(.opacity)
            }
            if alive { AgentChatFXLayer(fx: fx) }
        }
        .coordinateSpace(.named(Self.space))
        .onAppear(perform: appeared)
        #if DEBUG
        .onAppear { Self.isMounted = true }
        .onDisappear { Self.isMounted = false }
        #endif
        .onChange(of: model.phase, initial: true) { _, phase in
            fx.acting = phase == .acting
            fx.needsYou = phase == .needsYou
        }
        .onChange(of: model.entries.isEmpty, initial: true) { _, empty in fx.emptyThread = empty && shown }
        .onChange(of: shown) { _, now in
            fx.emptyThread = now && model.entries.isEmpty
            wipe(to: now)
        }
        .onChange(of: dark, initial: true) { _, now in fx.dark = now }
        .onReceive(model.effects) { effect in if alive { play(effect) } else { settle(effect) } }
    }

    /// New chat and Close, floating at the top once there is a thread.
    private var topControls: some View {
        HStack(spacing: 1) {
            AgentChatIconButton(systemName: "square.and.pencil", label: String(localized: "New chat"), action: model.newChat)
            AgentChatIconButton(systemName: "xmark", label: String(localized: "Close"), action: model.close)
        }
        .padding(2)
        .frame(height: AtticControlSize.headerControl)
        .background { Color.clear.atticRaisedMaterial(cornerRadius: 15, interactive: false) }
        .atticDesignCorners()
    }

    private func appeared() {
        fx.wipeOrigin = star
        if alive { fx.open(at: star) } else { fx.clearLive() }
        wipe(to: shown)
    }

    /// Runs the wipe (or, with Reduce Motion, the fade) to `open`.
    private func wipe(to open: Bool) {
        let target: CGFloat = open ? 1 : 0
        guard reveal != target else { return }
        withAnimation(alive ? AgentChatWipe.animation(opening: open) : .linear(duration: AgentChatStage.fade)) { reveal = target }
    }

    /// Reduce Motion's fade, in and out.
    static let fade = 0.2

    // MARK: The motion

    /// A row's frame in this stage. The rows report in the window's space.
    private func rowsOnStage(_ ids: Set<UUID>?) -> [(id: UUID, frame: CGRect)] {
        guard let backdropView else { return [] }
        return rows(ids).map { ($0.id, backdropView.convert($0.frame, from: nil)) }
    }

    private func play(_ effect: AgentChatEffect) {
        switch effect {
        case .sent:
            fx.addFlash(0.7)
            // After the row has laid out: the trail ends on the message.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                guard let composer = fx.composerFrame, let asked = fx.askedFrame else { return }
                fx.comet(from: CGPoint(x: composer.minX + composer.width * 0.7, y: composer.minY),
                         to: CGPoint(x: asked.maxX - 15, y: asked.minY + 8))
                fx.ring(composer.maxX - 11, composer.minY + 20, radius: 55, duration: 0.6)
            }
        case let .reading(step):
            let ids = Set(step.targets.compactMap(\.itemID))
            fx.scan(Array(rowsOnStage(ids.isEmpty ? nil : ids).map(\.frame).prefix(7)))
        case let .moving(step, week):
            moveChips(step, week: week)
        case let .deleting(step):
            let ids = Set(step.targets.compactMap(\.itemID))
            fx.turnToDust(step: step.id, rowsOnStage(ids).map(\.frame))
        case .approvalAllowed:
            if let card = fx.composerFrame { fx.dust(card, count: 130) }
            let at = fx.sparkPoint
            fx.ring(at.x, at.y, radius: 45, duration: 0.5)
        case .approvalDenied:
            break
        case .changesLanded:
            fx.landOnChanges()
        case let .undoing(changes):
            fx.undo(steps: changes.steps)
        }
    }

    /// Reduce Motion: only what the thread's state needs.
    private func settle(_ effect: AgentChatEffect) {
        if case let .moving(step, week?) = effect {
            step.targets.forEach { _ in model.dotLanded(week: week) }
        }
    }

    private func moveChips(_ step: AgentStep, week: UUID?) {
        let found = Dictionary(rowsOnStage(Set(step.targets.compactMap(\.itemID))).map { ($0.id, $0.frame) },
                               uniquingKeysWith: { first, _ in first })
        // The week strip's slot appears with this step: give it a few frames.
        var key: AgentChatFX.WeekSlot?
        if let week, case let .move(day?) = step.kind { key = AgentChatFX.WeekSlot(week: week, day: day) }
        whenWeekSlotIsReady(key) { slot in
            guard let slot else {
                if let week { step.targets.forEach { _ in model.dotLanded(week: week) } }
                return
            }
            #if DEBUG
            if let week { Self.chipFlights.append(week) }
            #endif
            let shownDots = min(4, step.targets.count)
            let moves = step.targets.enumerated().map { index, target in
                let dot = min(index, shownDots - 1)
                let y = slot.midY + (CGFloat(dot) - CGFloat(shownDots - 1) / 2) * 5.5
                return (title: target.title ?? "", row: target.itemID.flatMap { found[$0] },
                        to: CGPoint(x: slot.midX, y: y),
                        onLand: { if let week { model.dotLanded(week: week) } })
            }
            fx.fly(step: step.id, moves)
        }
    }

    private func whenWeekSlotIsReady(_ key: AgentChatFX.WeekSlot?, tries: Int = 8, _ body: @escaping (CGRect?) -> Void) {
        guard let key else { return body(nil) }
        if let slot = fx.weekSlots[key] { return body(slot) }
        guard tries > 0 else { return body(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { whenWeekSlotIsReady(key, tries: tries - 1, body) }
    }
}

/// A small round button on the floating controls.
struct AgentChatIconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(TasksPanelDesign.toneInk(.groupHeader, tokens: design.tokens).color)
                .frame(width: 23, height: 23)
                .background(hovered ? AgentChatFill.quiet(design) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// What the chat draws over the page shows only where the blur already is:
/// inside the wipe's circle, with the same soft rim, or at the fade's
/// opacity. The circle is the blur's, in the stage's space.
struct AgentChatWipeReveal: ViewModifier, Animatable {
    var reveal: CGFloat
    let wipe: AgentChatWipe
    let fades: Bool

    #if DEBUG
    /// Test seam: the circle's scale (or the fade) the thread was last drawn at.
    static var lastScale: CGFloat?
    #endif

    var animatableData: CGFloat {
        get { reveal }
        set { reveal = newValue }
    }

    func body(content: Content) -> some View {
        // One structure throughout, so the thread is never rebuilt as the
        // wipe ends: only the mask's own content changes.
        let open = min(max(reveal, 0), 1)
        content
            .opacity(fades ? Double(open) : 1)
            .mask {
                if fades || open >= 1 {
                    #if DEBUG
                    let _ = Self.lastScale = fades ? open : 1
                    #endif
                    Color.black
                } else {
                    GeometryReader { geometry in
                        let frame = geometry.frame(in: .named(AgentChatStage.space))
                        let scale = wipe.scale(reveal: open)
                        #if DEBUG
                        let _ = Self.lastScale = scale
                        #endif
                        RadialGradient(stops: [.init(color: .black, location: 0),
                                               .init(color: .black, location: 1 - AgentChatWipe.feather),
                                               .init(color: .clear, location: 1)],
                                       center: UnitPoint(x: (wipe.origin.x - frame.minX) / max(1, frame.width),
                                                         y: (wipe.origin.y - frame.minY) / max(1, frame.height)),
                                       startRadius: 0, endRadius: max(0.5, wipe.fullRadius * scale))
                    }
                }
            }
    }
}

/// The composer growing out of the ✦ and folding back into it: size, corner
/// and place from one progress, as the "+" card does from the "+".
private struct AgentChatGrow: ViewModifier, Animatable {
    var progress: CGFloat
    let card: CGSize
    /// How far left of the bar's end the ✦ sits.
    let starInset: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = min(max(progress, 0), 1)
        let side = AtticControlSize.headerControl
        let radius = ComposerGrow.closedRadius + (18 - ComposerGrow.closedRadius) * p
        let shape = AtticControlShape.shape(cornerRadius: radius, exponent: AtticShape.controlExponent)
        content
            .frame(width: side + (card.width - side) * p, height: side + (card.height - side) * p, alignment: .bottomLeading)
            .clipShape(shape)
            .background { Color.clear.atticRaisedMaterial(cornerRadius: radius, interactive: false) }
            .atticDesignCorners()
            .opacity(Double(p))
            .padding(.trailing, starInset * (1 - p))
    }
}

/// The input, in the bar's place. An approval takes its place, and it goes back.
struct AgentChatComposer: View {
    @ObservedObject var model: AgentChatModel
    let fx: AgentChatFX
    let shown: Bool
    let layout: PanelPageLayout
    let alive: Bool
    let setTyping: (Bool) -> Void
    let didClose: () -> Void

    @Environment(\.atticDesign) private var design
    @FocusState private var focused: Bool
    @State private var grown = false
    @State private var height: CGFloat = 62
    @State private var shake: CGFloat = 0

    /// Where the field's text and the mode's label both start, inside the card.
    private static let textInset: CGFloat = 4

    private var insets: EdgeInsets { PanelSharedBottomBar.plusInsets(layout: layout) }
    private var width: CGFloat { max(0, layout.panelSize.width - insets.leading - insets.trailing) }
    private var side: CGFloat { AtticControlSize.headerControl }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { if $0 != height { height = $0 } }
        }
        .modifier(AgentChatGrow(progress: grown ? 1 : 0, card: CGSize(width: width, height: height),
                                starInset: side + TasksDesignMetrics.footerGap))
        .overlay {
            if alive, model.phase == .acting || model.phase == .needsYou {
                AgentChatRim(fx: fx, urgent: model.phase == .needsYou).allowsHitTesting(false).transition(.opacity)
            }
        }
        .offset(x: shake)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(AgentChatStage.space)) } action: { frame in
            fx.composerFrame = frame
        }
        .frame(height: height, alignment: .bottomTrailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, insets.leading)
        .padding(.trailing, insets.trailing)
        .padding(.bottom, insets.bottom)
        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3), value: model.phase)
        .onChange(of: shown, initial: true) { _, now in transition(now) }
        .onChange(of: focused) { _, now in setTyping(now) }
        .onChange(of: model.draft) { old, new in if alive, new.count > old.count { fx.keystroke(count: new.count) } }
        .onReceive(model.effects) { effect in if effect == .approvalDenied, alive { deny() } }
    }

    private func transition(_ open: Bool) {
        guard let animation = ComposerMotion.animation(showing: open) else {
            grown = open
            if open { focusSoon() } else { setTyping(false); didClose() }
            return
        }
        if open {
            withAnimation(animation) { grown = true }
            focusSoon()
        } else {
            focused = false
            setTyping(false)
            withAnimation(animation) { grown = false }
            // The blur's wipe is the longest part of the close.
            DispatchQueue.main.asyncAfter(deadline: .now() + AgentChatWipe.closing.duration + 0.02) { didClose() }
        }
    }

    private func focusSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { if model.isOpen, model.approval == nil { focused = true } }
    }

    private func deny() {
        Task { @MainActor in
            for offset in [-4.5, 3.5, -2, 0] as [CGFloat] {
                withAnimation(.easeInOut(duration: 0.075)) { shake = offset }
                try? await Task.sleep(for: .seconds(0.075))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let approval = model.approval {
            approvalCard(approval).transition(.opacity.combined(with: .offset(y: 8)).combined(with: .scale(scale: 0.955)))
        } else {
            input.transition(.opacity)
        }
    }

    private var ink: Color { design.tokens.ink(.heading).color }

    private func approvalCard(_ approval: AgentApproval) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(approval.title)
                .font(.system(size: 11.5, weight: .semibold))
                .lineSpacing(3)
                .foregroundStyle(ink)
            Text(approval.targets.compactMap(\.title).joined(separator: " · "))
                .font(.system(size: 10.5))
                .lineSpacing(3)
                .foregroundStyle(TasksPanelDesign.toneInk(.date, tokens: design.tokens).color)
                .padding(.top, 1)
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                Button { model.resolveApproval(allow: false) } label: {
                    Text("Don’t allow").font(.system(size: 10.5, weight: .medium)).foregroundStyle(ink)
                        .padding(.horizontal, 10).frame(height: 23)
                        .background(AgentChatFill.quiet(design), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("agent-chat-deny")
                Button { model.resolveApproval(allow: true) } label: {
                    Text("Allow").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(onInk)
                        .padding(.horizontal, 12).frame(height: 23)
                        .background(ink, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("agent-chat-allow")
            }
            .padding(.top, 7)
        }
        .padding(EdgeInsets(top: 10, leading: 13, bottom: 8, trailing: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var onInk: Color { design.tokens.context.mode == .dark ? .black : .white }

    private var input: some View {
        let busy = model.phase != .idle
        let hasText = !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 3) {
            TextField(String(localized: "Ask Attic"), text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .lineLimit(1...4)
                .lineSpacing(3)
                .foregroundStyle(ink)
                .focused($focused)
                .padding(.horizontal, Self.textInset)
                .padding(.vertical, 2)
                .onSubmit(model.send)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) {
                        model.draft += "\n"
                    } else {
                        model.send()
                    }
                    return .handled
                }
                .accessibilityLabel(String(localized: "Message"))
                .accessibilityIdentifier("agent-chat-field")
            HStack(spacing: 1) {
                modePicker
                Spacer(minLength: 0)
                Button { busy ? model.stop() : model.send() } label: {
                    Image(systemName: busy ? "stop.fill" : "arrow.up")
                        .font(.system(size: busy ? 8.5 : 10.5, weight: .bold))
                        .foregroundStyle(onInk)
                        .frame(width: 22, height: 22)
                        .background(ink, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!busy && !hasText)
                .scaleEffect(busy || hasText ? 1 : 0.82)
                .opacity(busy || hasText ? 1 : 0.3)
                .animation(alive ? .timingCurve(0.3, 1.7, 0.5, 1, duration: 0.3) : nil, value: busy || hasText)
                .help(busy ? String(localized: "Stop") : String(localized: "Send"))
                .accessibilityLabel(busy ? String(localized: "Stop") : String(localized: "Send"))
                .accessibilityIdentifier("agent-chat-send")
            }
        }
        .padding(EdgeInsets(top: 7, leading: 9, bottom: 6, trailing: 6))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modePicker: some View {
        Menu {
            Picker(String(localized: "Mode"), selection: $model.mode) {
                ForEach(AgentChatMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 3) {
                Text(model.mode.title).font(.system(size: 10, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 6, weight: .bold))
            }
            .foregroundStyle(TasksPanelDesign.toneInk(.groupHeader, tokens: design.tokens).color)
            .padding(.leading, Self.textInset)
            .padding(.trailing, 6)
            .frame(height: 21)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("agent-chat-mode")
    }
}

/// The turning edge on the composer while the agent acts, amber when it needs
/// you. Mounted only then.
private struct AgentChatRim: View {
    @ObservedObject var fx: AgentChatFX
    let urgent: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: fx.isIdle)) { _ in
            let colours = urgent ? [AgentIris.amber, Color(red: 1, green: 130 / 255, blue: 90 / 255),
                                    Color(red: 1, green: 214 / 255, blue: 130 / 255), AgentIris.amber]
                : AgentIris.all + [AgentIris.blue]
            AtticControlShape.shape(cornerRadius: 18, exponent: AtticShape.controlExponent)
                .stroke(AngularGradient(colors: colours, center: .center, angle: .degrees(fx.angle)), lineWidth: 1.25)
                .padding(-1)
        }
        .accessibilityHidden(true)
    }
}
