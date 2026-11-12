import AppKit
import Combine
import SwiftUI

/// The ✦ in the bar. Closed, it says what the run is doing, as plain states.
struct AgentChatBarButton: View {
    @ObservedObject var bar: AgentChatBar
    let action: () -> Void
    /// Tests and off-screen renders: seconds into the breath, in place of
    /// the clock, so a frame can be drawn at a paused time.
    var frozenTime: Double? = nil

    @Environment(\.atticDesign) private var design
    @State private var hovered = false
    /// When the breath began: each Needs you starts at scale 1, as the CSS
    /// animation does when its class is added.
    @State private var breathStart = Date()

    var body: some View {
        let label = bar.state.label
        let breathes = AgentChatTriggerMotion.breathes(bar.state, reduceMotion: design.reduceMotion)
        Button(action: action) {
            HStack(spacing: 5) {
                TimelineView(.animation(paused: !breathes || frozenTime != nil)) { context in
                    let pose = AgentChatTriggerMotion.pose(bar.state, hovered: hovered, reduceMotion: design.reduceMotion,
                                                           time: frozenTime ?? context.date.timeIntervalSince(breathStart))
                    glyph(labelled: label != nil)
                        .frame(width: 11, height: 11)
                        .rotationEffect(.degrees(pose.rotation))
                        .scaleEffect(pose.scale)
                        .animation(breathes ? nil : AgentChatTriggerMotion.hover, value: hovered)
                }
                .frame(width: 11, height: 11)
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
        .onChange(of: breathes, initial: true) { _, now in if now { breathStart = Date() } }
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

/// The closed ✦'s motion, as drawn (`Preview - settings at bottom.dc.html`,
/// `[data-chat-trigger] svg` and `.ch-tg-need svg`). Hover turns the ✦ 90°
/// and scales it to 1.14 on `cubic-bezier(0.3, 1.7, 0.5, 1)` 460 ms. While
/// the agent needs you it breathes instead (`ch-breathe`: 1.2 s, scale 1 →
/// 1.18 → 1, ease-in-out each way), and the breath replaces the hover pose
/// (a CSS animation wins over the hover's transform). Reduce Motion (or
/// Animations: Reduced): neither; the label and the iris ✦ show the state.
/// Thinking and Working add no motion: the drawing's spark motions (tumble …
/// edge run) are a draft, and "Thinking still has no look" (Accepted 6 and
/// 10 Nov).
enum AgentChatTriggerMotion {
    static let hover = Animation.timingCurve(0.3, 1.7, 0.5, 1, duration: 0.46)
    static let hoverTurn: Double = 90
    static let hoverScale: CGFloat = 1.14
    static let breathPeriod: Double = 1.2
    static let breathPeak: CGFloat = 1.18

    static func breathes(_ state: AgentChatBarState, reduceMotion: Bool) -> Bool {
        state == .needsYou && !reduceMotion
    }

    /// The breath's scale `time` seconds into a cycle: CSS `ease-in-out`
    /// from 1 to the peak over the first half, and back over the second.
    static func breath(at time: Double) -> CGFloat {
        let phase = time.truncatingRemainder(dividingBy: breathPeriod) / breathPeriod
        // ease-in-out is symmetric, so the way down is the way up reversed.
        let half = phase < 0.5 ? phase * 2 : (1 - phase) * 2
        return 1 + (breathPeak - 1) * CGFloat(AgentEase.curve(0.42, 0, 0.58, 1, half))
    }

    static func pose(_ state: AgentChatBarState, hovered: Bool, reduceMotion: Bool,
                     time: Double) -> (rotation: Double, scale: CGFloat) {
        if breathes(state, reduceMotion: reduceMotion) { return (0, breath(at: time)) }
        let turned = hovered && !reduceMotion
        return (turned ? hoverTurn : 0, turned ? hoverScale : 1)
    }
}

/// Shows the alive layer in a window over the panel and the island (the
/// stage and the layer's state given), or puts it back on the stage (nil).
/// Answers whether the window took it.
typealias AgentChatReach = (_ target: (fx: AgentChatFX, stage: NSView)?) -> Bool

/// Hands the alive layer to the reach window and back, and tells the top row
/// while the chat watches the agent work. A view of its own, so neither
/// updates the stage's body.
private struct AgentChatStageRelay: View {
    @ObservedObject var fx: AgentChatFX
    let watching: Bool
    let stage: () -> NSView?
    let reach: AgentChatReach?

    @Environment(\.panelTopRowState) private var topRow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { fx.canReachOut = reach != nil }
            .onChange(of: fx.reachesOut) { _, out in
                // The window takes the layer, or the stage keeps it after all.
                if out {
                    guard let stage = stage(), reach?((fx, stage)) == true else { return fx.endReach() }
                } else {
                    _ = reach?(nil)
                }
            }
            .onChange(of: watching, initial: true) { _, now in
                if topRow?.chatWatching != now { topRow?.chatWatching = now }
            }
            .onDisappear {
                if fx.reachesOut { fx.endReach() }
                _ = reach?(nil)
                if topRow?.chatWatching == true { topRow?.chatWatching = false }
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
    /// Draws the alive layer past the panel's edge while the spark is out.
    var reach: AgentChatReach? = nil

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
                               didClose: { if !bar.isChatOpen { mounted = false } }, reach: reach)
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
    var reach: AgentChatReach? = nil

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
    /// The chat has stepped aside while it watches the agent work: the blur,
    /// its colour and the thread go; the composer and the floating controls
    /// stay, and the page's own top row shows beside them (the drawing's
    /// `watch(2)`).
    @State private var aside = false
    /// New chat: the old thread is leaving, upward (or, with Reduce Motion, fading).
    @State private var dispersing = false

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
            AgentChatBackdrop(shown: shown, reveal: reveal, clearing: model.watch.clearing, origin: star, tint: tint,
                              fades: !alive, solid: solid,
                              onEscape: { model.escape() },
                              didMake: { view in DispatchQueue.main.async { backdropView = view } })
                // The design's `backdrop-filter 420ms`; Reduce Motion's plain fade.
                .animation(alive ? .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.42) : .linear(duration: Self.fade),
                           value: model.watch)
                // Still there to click: a click while watching closes the chat.
                .overlay { Color.clear.contentShape(Rectangle()).onTapGesture { model.close() } }
                .accessibilityHidden(true)
            if alive {
                // Only the fade is eased here: the circle keeps the wipe's curve.
                AgentChatAuraLayer(fx: fx, reveal: reveal).animation(.easeOut(duration: 0.3)) { $0.opacity(shown && !aside ? 1 : 0) }
            }
            VStack(spacing: 0) {
                PanelControlFold(folded: !shown, animation: { _ in .easeOut(duration: 0.2) }) {
                    if model.entries.isEmpty {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { model.close() }
                    } else {
                        AgentChatThread(model: model, fx: fx, alive: alive, onAway: { model.close() })
                            .opacity(dispersing ? 0 : 1)
                            .scaleEffect(dispersing && alive ? 0.98 : 1)
                            .offset(y: dispersing && alive ? -23 : 0)
                            .allowsHitTesting(!dispersing)
                    }
                }
                // The thread arrives with the blur under it, never over the
                // page's still readable rows (screen 9): the wipe's circle,
                // or its fade.
                .modifier(AgentChatWipeReveal(reveal: reveal, wipe: AgentChatWipe(origin: star, size: layout.panelSize), fades: !alive))
                .opacity(aside ? 0 : 1)
                .allowsHitTesting(!aside)
                AgentChatComposer(model: model, fx: fx, shown: shown, layout: layout, alive: alive, setTyping: setTyping, didClose: didClose)
            }
            if !model.entries.isEmpty {
                PanelControlFold(folded: !shown, animation: { _ in .easeOut(duration: 0.2) }) { topControls }
                    .padding(.top, layout.chromeInsets.top)
                    .padding(.trailing, PanelSharedBottomBar.plusInsets(layout: layout).trailing)
                    .transition(.opacity)
            }
            if alive { AgentChatFXLayer(fx: fx) }
            AgentChatStageRelay(fx: fx, watching: model.watch == .watching, stage: { backdropView }, reach: alive ? reach : nil)
        }
        .coordinateSpace(.named(Self.space))
        // Pages report frames in the hosting view's global space.
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { fx.stageOrigin = $0 }
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
            #if DEBUG && ATTIC_LOCAL_ONLY
            if now { DispatchQueue.main.async { AgentPassProbe.stageUpdated() } }
            #endif
        }
        .onChange(of: dark, initial: true) { _, now in fx.dark = now }
        .onChange(of: model.watch == .watching) { _, now in
            // The design's 280 ms; Reduce Motion's plain fade.
            withAnimation(alive ? .easeOut(duration: 0.28) : .linear(duration: Self.fade)) { aside = now }
        }
        .onReceive(model.effects) { effect in if alive { play(effect) } else { settle(effect) } }
    }

    /// Chats, New chat and Close, floating at the top once there is a thread.
    private var topControls: some View {
        HStack(spacing: 1) {
            AgentChatHistoryButton(model: model)
            AgentChatIconButton(systemName: "square.and.pencil", label: String(localized: "New chat"), action: startNewChat)
                .agentChatUITestTarget("agent-chat-new")
            AgentChatIconButton(systemName: "xmark", label: String(localized: "Close"), action: model.close)
        }
        .padding(2)
        .frame(height: AtticControlSize.headerControl)
        .background { Color.clear.atticRaisedMaterial(cornerRadius: 15, interactive: false) }
        .atticDesignCorners()
    }

    /// The design's reset: the old thread lifts 46 (23 here) and fades in
    /// 240 ms, ease-in, with a burst of 22 at its middle; then the new chat.
    /// Reduce Motion: a plain fade.
    private func startNewChat() {
        guard !dispersing else { return }
        let duration = alive ? 0.24 : Self.fade
        if alive, let composer = fx.composerFrame {
            fx.burst(layout.panelSize.width / 2, composer.minY * 0.4, count: 22, speed: 120)
        }
        withAnimation(alive ? .easeIn(duration: duration) : .linear(duration: duration)) { dispersing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            model.newChat()
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { dispersing = false }
        }
    }

    private func appeared() {
        #if DEBUG && ATTIC_LOCAL_ONLY
        if shown { DispatchQueue.main.async { AgentPassProbe.stageUpdated() } }
        #endif
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
        case .approvalDenied, .watchEnded:
            break
        case let .pointer(point):
            fx.point(at: point.flatMap(onStage))
        case let .tap(point):
            if let at = onStage(point) { fx.tap(at: at) }
        case let .burst(point, count, speed, ring):
            guard let at = onStage(point) else { return }
            if count == 1 {
                fx.star(at.x, at.y, vy: Double.random(in: -13 ... 2), life: Double.random(in: 0.3 ... 0.6), size: Double.random(in: 1 ... 2.25))
            } else {
                fx.burst(at.x, at.y, count: count, speed: speed)
            }
            if ring > 0 { fx.ring(at.x, at.y, radius: ring, duration: 0.5) }
        case let .ping(rect, duration):
            if let frame = onStage(rect) { fx.ping(frame, duration: duration, holds: true) }
        case let .pingRows(ids):
            for row in rowsOnStage(Set(ids)) { fx.ping(row.frame, duration: 0.9, holds: false) }
        case let .sketch(replay):
            guard let backdropView else { return }
            let origin = backdropView.convert(CGPoint.zero, from: nil)
            let down = backdropView.convert(CGPoint(x: 0, y: 1), from: nil).y - origin.y
            fx.sketch(replay, transform: CGAffineTransform(a: 1, b: 0, c: 0, d: down, tx: origin.x, ty: origin.y))
        case .changesLanded:
            fx.landOnChanges()
        case let .undoing(changes):
            fx.undo(steps: changes.steps)
        case let .writing(point, star):
            guard let backdropView else { return }
            fx.write(at: backdropView.convert(point, from: nil), star: star)
        }
    }

    /// A watched point on this stage: from the window, or the global space.
    private func onStage(_ point: AgentWatchPoint) -> CGPoint? {
        switch point.space {
        case .window: return backdropView?.convert(point.point, from: nil)
        case .global: return CGPoint(x: point.point.x - fx.stageOrigin.x, y: point.point.y - fx.stageOrigin.y)
        }
    }

    private func onStage(_ rect: AgentWatchRect) -> CGRect? {
        switch rect.space {
        case .window: return backdropView?.convert(rect.rect, from: nil)
        case .global: return rect.rect.offsetBy(dx: -fx.stageOrigin.x, dy: -fx.stageOrigin.y)
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

/// What the agent is doing on the page while the chat steps aside, over
/// the composer: the running step's shimmer on a small raised pill.
struct AgentChatLiveLabel: View {
    let text: String
    let alive: Bool
    @Environment(\.atticDesign) private var design

    var body: some View {
        let ink = design.tokens.ink(.heading).color
        Group {
            if alive { AgentChatShimmerText(text: text, ink: ink) } else { Text(text).foregroundStyle(ink) }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .lineLimit(1)
        .fixedSize()
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background { Color.clear.atticRaisedMaterial(cornerRadius: 10, interactive: false) }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
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

    /// The phase drives composer geometry; keep its transaction distinct from
    /// the label's reduced-motion fade above it.
    static func phaseAnimation(alive: Bool) -> Animation? {
        alive ? .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3) : nil
    }

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
        .overlay(alignment: .top) {
            if let label = model.liveLabel {
                // The drawing's `bottom: calc(100% + 14px)`: its bottom 7 pt
                // above the composer's top, whatever the composer holds.
                AgentChatLiveLabel(text: label, alive: alive)
                    .frame(height: 0, alignment: .bottom)
                    .offset(y: -7)
                    .transition(alive ? .opacity.combined(with: .scale(scale: 0.97)).combined(with: .offset(y: 4)) : .opacity)
            }
        }
        .animation(alive ? .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.34) : .linear(duration: AgentChatStage.fade),
                   value: model.liveLabel)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(AgentChatStage.space)) } action: { frame in
            fx.composerFrame = frame
        }
        .frame(height: height, alignment: .bottomTrailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, insets.leading)
        .padding(.trailing, insets.trailing)
        .padding(.bottom, insets.bottom)
        .animation(Self.phaseAnimation(alive: alive), value: model.phase)
        .onChange(of: shown, initial: true) { _, now in transition(now) }
        .onChange(of: focused) { _, now in setTyping(now) }
        .onChange(of: model.pickingItem) { _, now in if !now { focusSoon() } }
        .onChange(of: model.draft) { old, new in if alive, new.count > old.count { fx.keystroke(count: new.count) } }
        .onReceive(model.effects) { effect in
            if effect == .approvalDenied, alive { deny() }
            if effect == .watchEnded { focusSoon() }
        }
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
            AgentChatContextChips(model: model)
            if model.pickingItem {
                AgentChatItemPicker(model: model, done: { model.pickingItem = false })
            } else {
                field
            }
            HStack(spacing: 1) {
                addMenu
                // The glass menu (Accepted 2026-11-10): the same choices,
                // the current one ticked, a reason or description as the
                // row's trailing value.
                AgentChatPickerMenu(identifier: "agent-chat-agent", label: model.agent.shortTitle,
                                    commands: AgentBackend.allCases.map { choice in
                    var command = AtticMenuCommand(verbatim: choice.shortTitle, state: model.agent == choice ? .on : .off) {
                        model.agent = choice
                    }
                    if let reason = model.agentUnavailable[choice] {
                        command.detail = reason
                        command.isDisabled = true
                        command.disabledReason = reason
                    }
                    return command
                })
                AgentChatPickerMenu(identifier: "agent-chat-mode", label: model.mode.title,
                                    commands: AgentChatMode.allCases.map { choice in
                    var command = AtticMenuCommand(verbatim: choice.title, state: model.mode == choice ? .on : .off) {
                        model.mode = choice
                    }
                    command.detail = choice.description
                    return command
                })
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
        .animation(alive ? .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24) : .linear(duration: AgentChatStage.fade),
                   value: model.pickingItem)
    }

    private var field: some View {
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
    }

    /// The design's +: Task or note…, This page, File….
    private var addMenu: some View {
        AtticCommandMenu(commands: [
            AtticMenuCommand("Task or note…") { model.pickingItem = true },
            AtticMenuCommand("This page") { model.addPage() },
            AtticMenuCommand("File…") { pickFile() },
        ], accessibilityLabel: String(localized: "Add a task, note or file")) {
            Image(systemName: "plus")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(TasksPanelDesign.toneInk(.groupHeader, tokens: design.tokens).color)
                .frame(width: 21, height: 21)
                .contentShape(Rectangle())
        }
        .help(String(localized: "Add a task, note or file"))
        .accessibilityLabel(String(localized: "Add a task, note or file"))
        .accessibilityIdentifier("agent-chat-add")
        .agentChatUITestTarget("agent-chat-add")
    }

    /// The standard open panel, text files only. Its grant covers the one
    /// file picked, which is read at once (`AgentChatFiles`).
    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = AgentChatFiles.types
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.attachFile(at: url)
            focusSoon()
        }
    }
}

/// One of the composer's labelled menus (the agent, the mode): its label
/// and a chevron, opening Attic's glass menu.
private struct AgentChatPickerMenu: View {
    let identifier: String
    let label: String
    let commands: [AtticMenuCommand]
    @Environment(\.atticDesign) private var design

    var body: some View {
        AtticCommandMenu(commands: commands, accessibilityLabel: label) {
            HStack(spacing: 3) {
                Text(label).font(.system(size: 10, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 6, weight: .bold))
            }
            .foregroundStyle(TasksPanelDesign.toneInk(.groupHeader, tokens: design.tokens).color)
            .padding(.horizontal, 6)
            .frame(height: 21)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier(identifier)
        .agentChatUITestTarget(identifier)
    }
}

/// Over the field: the page chip (`Tasks ×`), then whatever + added, and a
/// refused file's reason. Nothing at all when there is none.
private struct AgentChatContextChips: View {
    @ObservedObject var model: AgentChatModel
    @Environment(\.atticDesign) private var design

    var body: some View {
        let page = model.includesPage ? model.chipPage : nil
        if page != nil || !model.attachments.isEmpty || model.attachmentRefusal != nil {
            VStack(alignment: .leading, spacing: 3) {
                if page != nil || !model.attachments.isEmpty {
                    AgentChatChipFlow(spacing: 4) {
                        if let page {
                            chip(page.rawValue.capitalized, identifier: "agent-chat-page-chip") { model.removePage() }
                        }
                        ForEach(model.attachments) { attachment in
                            chip(attachment.name, identifier: "agent-chat-chip") { model.removeAttachment(attachment.id) }
                        }
                    }
                }
                if let refusal = model.attachmentRefusal {
                    Text(refusal)
                        .font(.system(size: 9.5))
                        .foregroundStyle(TasksPanelDesign.toneInk(.date, tokens: design.tokens).color)
                        .padding(.leading, 3)
                        .accessibilityIdentifier("agent-chat-file-refusal")
                        .task(id: refusal) {
                            try? await Task.sleep(for: .seconds(4))
                            if !Task.isCancelled { model.clearAttachmentRefusal() }
                        }
                }
            }
            .padding(.bottom, 3)
        }
    }

    private func chip(_ name: String, identifier: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(TasksPanelDesign.toneInk(.groupHeader, tokens: design.tokens).color)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 6.5, weight: .semibold))
                    .foregroundStyle(TasksPanelDesign.toneInk(.date, tokens: design.tokens).color)
                    .frame(width: 11, height: 11)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Remove"))
            .accessibilityLabel(String(localized: "Remove"))
            .agentChatUITestTarget(identifier + "-remove")
        }
        .padding(.leading, 7)
        .padding(.trailing, 4)
        .frame(height: 18)
        .frame(maxWidth: 160, alignment: .leading)
        .fixedSize()
        .background(AgentChatFill.quiet(design), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// Chips in a row, wrapping onto the next line when the row is full.
private struct AgentChatChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if var last = rows.last, last.width + spacing + size.width <= width {
                last.items.append(index)
                last.width += spacing + size.width
                last.height = max(last.height, size.height)
                rows[rows.count - 1] = last
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}

/// Task or note…: the field turns into a search over tasks and notes; a
/// pick becomes a chip. Escape, or an empty field left, goes back.
private struct AgentChatItemPicker: View {
    @ObservedObject var model: AgentChatModel
    let done: () -> Void
    @Environment(\.atticDesign) private var design
    @FocusState private var focused: Bool
    @State private var query = ""
    @State private var highlighted = 0

    var body: some View {
        let results = model.searchItems(query)
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(results.enumerated()), id: \.offset) { index, target in
                Button { pick(target) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: target.page == .notes ? "note.text" : "circle")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(TasksPanelDesign.toneInk(.date, tokens: design.tokens).color)
                            .frame(width: 12)
                        Text(target.title ?? "")
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .foregroundStyle(design.tokens.ink(.heading).color)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 4)
                    .frame(height: 22)
                    .background(index == highlighted ? AgentChatFill.quiet(design) : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { highlighted = index } }
                .accessibilityIdentifier("agent-chat-pick-result")
                .agentChatUITestTarget("agent-chat-pick-result-\(index)")
            }
            TextField(String(localized: "Task or note…"), text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel(String(localized: "Find a task or note"))
                .font(.system(size: 11.5))
                .foregroundStyle(design.tokens.ink(.heading).color)
                .focused($focused)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .onChange(of: query) { _, _ in highlighted = 0 }
                .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(0, results.count - 1)); return .handled }
                .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                .onKeyPress(.return) {
                    if results.indices.contains(highlighted) { pick(results[highlighted]) } else { done() }
                    return .handled
                }
                .accessibilityIdentifier("agent-chat-pick-field")
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
        #if DEBUG
        .onReceive(model.$uiTestQuery) { if let typed = $0 { query = typed } }
        #endif
    }

    private func pick(_ target: AgentTarget) {
        model.attach(target)
        done()
    }
}

/// The clock: the saved chats, newest first, each with its day; one reopens.
struct AgentChatHistoryButton: View {
    @ObservedObject var model: AgentChatModel
    @Environment(\.atticDesign) private var design
    @State private var hovered = false

    var body: some View {
        AtticCommandMenu(commands: model.history.map { chat in
            AtticMenuCommand(verbatim: chat.title, isDisabled: model.isBusy,
                             detail: AgentChatModel.dayLabel(chat.updated)) { model.reopen(chat.id) }
        }, accessibilityLabel: String(localized: "Chats")) {
            Image(systemName: "clock")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(TasksPanelDesign.toneInk(.groupHeader, tokens: design.tokens).color)
                .frame(width: 23, height: 23)
                .background(hovered ? AgentChatFill.quiet(design) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
        }
        .onHover { hovered = $0 }
        .help(String(localized: "Chats"))
        .accessibilityLabel(String(localized: "Chats"))
        .accessibilityIdentifier("agent-chat-history")
        .agentChatUITestTarget("agent-chat-history")
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
