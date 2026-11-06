import SwiftUI

/// The ✦ itself: the design's four-point star.
struct AgentSparkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(12, 1.5))
        path.addCurve(to: p(22.5, 12), control1: p(12.9, 7.7), control2: p(15.8, 10.7))
        path.addCurve(to: p(12, 22.5), control1: p(15.8, 13.3), control2: p(12.9, 16.3))
        path.addCurve(to: p(1.5, 12), control1: p(11.1, 16.3), control2: p(8.2, 13.3))
        path.addCurve(to: p(12, 1.5), control1: p(8.2, 10.7), control2: p(11.1, 7.7))
        path.closeSubpath()
        return path
    }
}

/// The one place a thinking look goes (Accepted 2026-11-06: none for now, to be
/// designed properly later). It sits at the end of the thread for the whole
/// gap before the first text or step, and shows nothing.
struct AgentChatWaitingSlot: View {
    var body: some View { EmptyView() }
}

/// A word's place in the reply, so the renderer can time each one.
struct AgentWordAttribute: TextAttribute {
    var index: Int
    var key: Int?
}

/// Writes a reply word by word, each coming out of a blur, then draws the key
/// words' underlines. One `Text`, so wrapping and spacing stay native.
struct AgentWordRenderer: TextRenderer {
    var now: Date
    var times: [Date]
    var marksStart: Date?
    var paragraph: Int
    var probe: AgentWordProbe?

    var displayPadding: EdgeInsets { EdgeInsets(top: 4, leading: 3, bottom: 5, trailing: 3) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var marks: [(key: Int, rect: CGRect)] = []
        var newest: CGRect?
        for line in layout {
            for run in line {
                guard let word = run[AgentWordAttribute.self], word.index < times.count else {
                    context.draw(run)
                    continue
                }
                let age = now.timeIntervalSince(times[word.index])
                guard age > 0 else { continue }
                let rect = run.typographicBounds.rect
                if age < 0.44 {
                    newest = rect
                    var c = context
                    let fade = min(1, age / 0.34)
                    c.opacity = fade * fade * (3 - 2 * fade)
                    c.translateBy(x: 0, y: 2.5 * (1 - AgentEase.settle(age / 0.44)))
                    if fade < 1 { c.addFilter(.blur(radius: 3.5 * (1 - fade))) }
                    c.draw(run)
                } else {
                    context.draw(run)
                }
                if let key = word.key {
                    if let index = marks.lastIndex(where: { $0.key == key && abs($0.rect.midY - rect.midY) < 2 }) {
                        marks[index].rect = marks[index].rect.union(rect)
                    } else {
                        marks.append((key, rect))
                    }
                }
            }
        }
        if let newest { probe?.report(paragraph: paragraph, rect: newest, time: now) }
        guard let marksStart else { return }
        for (order, mark) in marks.enumerated() {
            let age = now.timeIntervalSince(marksStart) - Double(order) * 0.17
            guard age > 0 else { continue }
            let path = Self.underline(under: mark.rect).trimmedPath(from: 0, to: AgentEase.curve(0, 0, 0.58, 1, age / 0.62))
            context.stroke(path, with: .linearGradient(AgentIris.underline,
                                                       startPoint: CGPoint(x: mark.rect.minX, y: 0),
                                                       endPoint: CGPoint(x: mark.rect.maxX, y: 0)),
                           style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        }
    }

    /// The design's hand-drawn line, stretched under `rect`.
    static func underline(under rect: CGRect) -> Path {
        let left = rect.minX - 1, width = rect.width + 2, top = rect.maxY - 1.5
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: left + x / 100 * width, y: top + y / 10 * 4.5) }
        var path = Path()
        path.move(to: p(1, 6))
        path.addCurve(to: p(40, 5), control1: p(14, 1), control2: p(26, 9))
        path.addCurve(to: p(80, 6), control1: p(54, 1), control2: p(66, 2))
        path.addCurve(to: p(99, 4), control1: p(94, 10), control2: p(94, 7))
        return path
    }
}

/// A floating line of text: the design's soft glow keeps it readable on the
/// blur in every appearance.
private struct AgentChatGlow: ViewModifier {
    let dark: Bool
    func body(content: Content) -> some View {
        let colour = dark ? Color.black : Color.white
        content
            .shadow(color: colour.opacity(dark ? 0.7 : 0.95), radius: 5)
            .shadow(color: colour.opacity(dark ? 0.6 : 0.9), radius: 1.5)
    }
}

/// The conversation: bare text floating on the blur. Sending puts the message
/// at the top and the reply fills in under it.
struct AgentChatThread: View {
    @ObservedObject var model: AgentChatModel
    let fx: AgentChatFX
    let alive: Bool
    /// Tapping open space in the thread closes the chat.
    let onAway: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var viewport: CGFloat = 0
    @State private var turnHeight: CGFloat = 0
    @State private var followsEnd = true

    static let topInset: CGFloat = 52
    static let sideInset: CGFloat = 22
    static let bottomInset: CGFloat = 11
    private static let gap: CGFloat = 7
    private static let tail = "agent-chat-tail"
    private static let turnTop = "agent-chat-turn"

    private var turnStart: Int { model.entries.lastIndex { if case .asked = $0.content { true } else { false } } ?? 0 }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Self.gap) {
                    ForEach(model.entries[..<turnStart]) { row($0, viewport: viewport) }
                    // The anchor reaches up over the gap, so a turn rests
                    // clear of the top controls with no hole between turns.
                    Color.clear.frame(height: Self.topInset).id(Self.turnTop)
                        .padding(.top, turnStart == 0 ? 0 : Self.gap - Self.topInset)
                    VStack(alignment: .leading, spacing: Self.gap) {
                        ForEach(model.entries[turnStart...]) { row($0, viewport: viewport) }
                        if model.phase == .waiting { AgentChatWaitingSlot() }
                    }
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { turnHeight = $0 }
                    .frame(minHeight: max(0, viewport - Self.topInset - Self.bottomInset), alignment: .top)
                    Color.clear.frame(height: 1).id(Self.tail)
                }
                .padding(.horizontal, Self.sideInset)
                .padding(.bottom, Self.bottomInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.clear.contentShape(Rectangle()).onTapGesture(perform: onAway))
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { viewport = $0 }
            .onScrollPhaseChange { _, phase in if phase == .interacting { followsEnd = false } }
            .onChange(of: turnStart, initial: true) { _, _ in
                followsEnd = true
                proxy.scrollTo(Self.turnTop, anchor: .top)
            }
            .onChange(of: turnHeight) { _, height in
                guard followsEnd, height > viewport - Self.topInset - Self.bottomInset else { return }
                withAnimation(alive ? .easeOut(duration: 0.25) : nil) { proxy.scrollTo(Self.tail, anchor: .bottom) }
            }
        }
        // The design's fade under the top controls and into the composer.
        .mask {
            GeometryReader { geometry in
                let height = max(1, geometry.size.height)
                LinearGradient(stops: [
                    .init(color: .clear, location: min(0.4, 31 / height)),
                    .init(color: .black, location: min(0.5, 50 / height)),
                    .init(color: .black, location: max(0.6, 1 - 11 / height)),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: AgentChatEntry, viewport: CGFloat) -> some View {
        let dark = design.tokens.context.mode == .dark
        let first = !model.wasShown(entry.id)
        Group {
            content(entry, first: first, viewport: viewport, dark: dark)
        }
        .onAppear { model.noteShown(entry.id) }
    }

    @ViewBuilder
    private func content(_ entry: AgentChatEntry, first: Bool, viewport: CGFloat, dark: Bool) -> some View {
        switch entry.content {
        case let .asked(text):
            AgentAskedRow(text: text, first: first, alive: alive, viewport: viewport, fx: fx)
                .modifier(AgentChatGlow(dark: dark))
        case let .step(step):
            AgentStepRow(step: step, alive: alive, fx: fx).modifier(AgentChatGlow(dark: dark))
        case let .week(week):
            AgentWeekStrip(id: entry.id, week: week, first: first, alive: alive,
                           running: model.phase != .idle && model.runWeek == entry.id, fx: fx)
        case let .reply(reply):
            AgentReplyView(reply: reply, fx: fx).modifier(AgentChatGlow(dark: dark))
        case let .changes(changes):
            AgentChangesRow(changes: changes, first: first, alive: alive, fx: fx,
                            toggle: { model.toggleChanges(entry.id) }, undo: { model.undo(entry.id) })
        case let .note(text):
            Text(text)
                .font(.system(size: 10.5))
                .lineSpacing(3)
                .foregroundStyle(TasksPanelDesign.toneInk(.date, tokens: design.tokens).color)
                .modifier(AgentChatGlow(dark: dark))
        }
    }
}

/// What you sent: right-aligned and bold. It rises from the composer.
private struct AgentAskedRow: View {
    let text: String
    let first: Bool
    let alive: Bool
    let viewport: CGFloat
    let fx: AgentChatFX

    @Environment(\.atticDesign) private var design
    @State private var rise: CGFloat

    init(text: String, first: Bool, alive: Bool, viewport: CGFloat, fx: AgentChatFX) {
        self.text = text
        self.first = first
        self.alive = alive
        self.viewport = viewport
        self.fx = fx
        _rise = State(initialValue: first ? 1 : 0)
    }

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Text(text)
                .font(.system(size: 11.5, weight: .semibold))
                .lineSpacing(3)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(design.tokens.ink(.heading).color)
                .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in width * 0.84 }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(AgentChatStage.space)) } action: { fx.askedFrame = $0 }
        }
        .offset(y: rise * max(0, viewport - AgentChatThread.topInset - AgentChatThread.bottomInset - 16))
        .scaleEffect(1 - 0.06 * rise, anchor: .trailing)
        .blur(radius: 1.25 * rise)
        .opacity(1 - 0.5 * rise)
        .onAppear {
            guard rise > 0 else { return }
            withAnimation(alive ? .spring(duration: 0.56, bounce: 0.25) : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.42)) { rise = 0 }
        }
    }
}

/// A tool row: the spark works in its slot, and a tick draws itself when done.
private struct AgentStepRow: View {
    let step: AgentStep
    let alive: Bool
    let fx: AgentChatFX

    @Environment(\.atticDesign) private var design
    @State private var tick: CGFloat = 1

    private var running: Bool { step.state == .running }

    var body: some View {
        let ink = running ? design.tokens.ink(.heading).color
            : TasksPanelDesign.toneInk(.groupHeader, tokens: design.tokens).color
        HStack(spacing: 6) {
            slot(ink).frame(width: 11, height: 11)
            title(ink)
                .font(.system(size: 10.5))
                .lineSpacing(3)
        }
        .onChange(of: running) { _, now in
            guard !now, alive else { return }
            tick = 0
            withAnimation(.easeOut(duration: 0.46)) { tick = 1 }
        }
    }

    @ViewBuilder
    private func slot(_ ink: Color) -> some View {
        if running {
            if alive {
                Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(AgentChatStage.space)) } action: { fx.toolSlot = $0 }
                    .onDisappear { fx.toolSlot = nil }
            } else {
                Circle().stroke(ink.opacity(0.7), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: [1.5, 2.7]))
            }
        } else if case .failed = step.state, !step.title.isEmpty, step.title != String(localized: "Stopped") {
            Image(systemName: "xmark.circle").font(.system(size: 10)).foregroundStyle(ink)
        } else {
            AgentTick(progress: tick).stroke(ink, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        }
    }

    @ViewBuilder
    private func title(_ ink: Color) -> some View {
        if running, alive {
            // The doing line's shimmer: a step is running, so this is work
            // being done, never a thinking look.
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.7) / 1.7
                let start = -2.34 + 4.68 * (1 - phase)
                Text(step.title).foregroundStyle(LinearGradient(
                    stops: [.init(color: ink, location: 0.32), .init(color: AgentIris.blue, location: 0.46),
                            .init(color: AgentIris.pink, location: 0.54), .init(color: ink, location: 0.68)],
                    startPoint: UnitPoint(x: start, y: 0.5), endPoint: UnitPoint(x: start + 2.8, y: 0.5)))
            }
        } else {
            Text(step.title).foregroundStyle(ink)
        }
    }
}

/// The design's tick: a ring, then the check, drawn in turn.
private struct AgentTick: Shape {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        let ring = min(1, progress / 0.87)
        let check = max(0, (progress - 0.43) / 0.57)
        var path = Path()
        path.addArc(center: CGPoint(x: 12 * s, y: 12 * s), radius: 10 * s, startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360 * ring), clockwise: false)
        var mark = Path()
        mark.move(to: CGPoint(x: 7.6 * s, y: 12.3 * s))
        mark.addLine(to: CGPoint(x: 10.8 * s, y: 15.5 * s))
        mark.addLine(to: CGPoint(x: 16.6 * s, y: 9 * s))
        path.addPath(mark.trimmedPath(from: 0, to: check))
        return path
    }
}

/// The reply: word by word while it writes, plain text once it has settled.
private struct AgentReplyView: View {
    let reply: AgentChatReply
    let fx: AgentChatFX

    @Environment(\.atticDesign) private var design
    @State private var settled = false

    /// When the last word and underline have finished.
    private var settlesAt: Date? {
        guard let marksStart = reply.marksStart else { return nil }
        guard marksStart != .distantPast else { return .distantPast }
        let keys = Set(AgentChatWords.paragraphs(reply.raw).flatMap { $0 }.compactMap(\.key)).count
        return marksStart.addingTimeInterval(0.62 + 0.17 * Double(keys))
    }

    var body: some View {
        let paragraphs = AgentChatWords.paragraphs(reply.raw)
        let starts = paragraphs.reduce(into: [0]) { $0.append(($0.last ?? 0) + $1.count) }
        TimelineView(.animation(paused: settled)) { timeline in
            VStack(alignment: .leading, spacing: 5) {
                ForEach(paragraphs.indices, id: \.self) { index in
                    text(paragraphs[index], first: starts[index])
                        .textRenderer(AgentWordRenderer(now: timeline.date, times: reply.wordTimes, marksStart: reply.marksStart,
                                                        paragraph: index, probe: fx.word))
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(AgentChatStage.space)) } action: { fx.paragraphFrames[index] = $0 }
                }
            }
        }
        .font(.system(size: 11.5))
        .lineSpacing(3.5)
        .foregroundStyle(design.tokens.ink(.heading).color)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reply.raw.replacingOccurrences(of: "**", with: ""))
        .task(id: settlesAt) {
            guard let settlesAt else { return }
            let wait = settlesAt.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if !Task.isCancelled { settled = true }
        }
    }

    private func text(_ words: [AgentChatWords.Word], first: Int) -> Text {
        var text = Text("")
        for (index, word) in words.enumerated() {
            if index > 0, !word.joinsPrevious { text = text + Text(verbatim: " ") }
            text = text + Text(verbatim: word.text).customAttribute(AgentWordAttribute(index: first + index, key: word.key))
        }
        return text
    }
}

/// The week filling in, and the day moved tasks land on.
private struct AgentWeekStrip: View {
    let id: UUID
    let week: AgentChatWeek
    let first: Bool
    let alive: Bool
    let running: Bool
    let fx: AgentChatFX

    @Environment(\.atticDesign) private var design
    @State private var filled: Bool
    @State private var arrived: Bool
    @State private var glow = false

    init(id: UUID, week: AgentChatWeek, first: Bool, alive: Bool, running: Bool, fx: AgentChatFX) {
        self.id = id
        self.week = week
        self.first = first
        self.alive = alive
        self.running = running
        self.fx = fx
        // A strip seen before is whole from its first frame.
        _filled = State(initialValue: !(first && alive))
        _arrived = State(initialValue: !(first && alive))
    }

    private static let target = Color(red: 84 / 255, green: 92 / 255, blue: 210 / 255)

    var body: some View {
        let calendar = Calendar.autoupdatingCurrent
        let barsBefore = week.days.reduce(into: [0]) { $0.append(($0.last ?? 0) + $1.bars.count) }
        HStack(spacing: 4.5) {
            ForEach(Array(week.days.enumerated()), id: \.element.id) { index, day in
                let isTarget = week.target.map { calendar.isDate($0, inSameDayAs: day.day) } ?? false
                let isToday = calendar.isDateInToday(day.day)
                VStack(spacing: 3) {
                    column(day, firstBar: barsBefore[index], isTarget: isTarget)
                    Text(verbatim: "\(day.day.formatted(.dateTime.weekday(.narrow))) \(calendar.component(.day, from: day.day))")
                        .font(.system(size: 8.5, weight: isToday ? .bold : .medium))
                        .lineLimit(1)
                        .foregroundStyle(isToday ? design.tokens.ink(.heading).color
                                         : isTarget ? Self.target : TasksPanelDesign.toneInk(.date, tokens: design.tokens).color)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background { Color.clear.atticRaisedMaterial(cornerRadius: 12, interactive: false) }
        .atticDesignCorners()
        .opacity(arrived ? 1 : 0)
        .offset(y: arrived ? 0 : 8)
        .scaleEffect(arrived ? 1 : 0.955)
        .onAppear(perform: appear)
    }

    private func appear() {
        guard !arrived else { return }
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.52)) { arrived = true }
        filled = true
    }

    private func column(_ day: AgentChatWeekDay, firstBar: Int, isTarget: Bool) -> some View {
        let tint = design.tokens.ink(.heading).color
        return GeometryReader { geometry in
            let height = geometry.size.height
            ZStack(alignment: .topLeading) {
                ForEach(Array(day.bars.enumerated()), id: \.offset) { index, bar in
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(tint.opacity(0.17))
                        .frame(height: height * (bar.upperBound - bar.lowerBound))
                        .scaleEffect(x: 1, y: filled ? 1 : 0, anchor: .top)
                        .animation(alive ? .timingCurve(0.2, 0.9, 0.2, 1, duration: 0.42).delay(Double(firstBar + index) * 0.042) : nil, value: filled)
                        .offset(y: height * bar.lowerBound)
                }
                if isTarget, week.read || week.dots > 0 {
                    slot.frame(width: geometry.size.width - 2, height: height * 0.53).offset(x: 1, y: height * 0.44)
                }
            }
        }
        .frame(height: 38)
        .background { RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(tint.opacity(0.045)) }
    }

    private var slotKey: AgentChatFX.WeekSlot? { week.target.map { AgentChatFX.WeekSlot(week: id, day: $0) } }

    private var slot: some View {
        VStack(spacing: 1.5) {
            ForEach(0..<min(4, week.dots), id: \.self) { index in
                Circle().fill(design.tokens.ink(.heading).color)
                    .frame(width: 4, height: 4)
                    .scaleEffect(index < week.landed ? 1 : 0)
                    .animation(alive ? .timingCurve(0.3, 1.8, 0.5, 1, duration: 0.46) : nil, value: week.landed)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
            shape.strokeBorder(glow ? AgentIris.pink.opacity(0.85) : AgentIris.blue.opacity(0.8), lineWidth: 1)
                .shadow(color: (glow ? AgentIris.pink : AgentIris.blue).opacity(0.4), radius: glow ? 5 : 3)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(AgentChatStage.space)) } action: { frame in
            if let slotKey { fx.weekSlots[slotKey] = frame }
        }
        .onDisappear { if let slotKey { fx.weekSlots[slotKey] = nil } }
        .onChange(of: running, initial: true) { _, now in
            guard alive else { return }
            if now {
                withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) { glow = true }
            } else {
                withAnimation(.easeOut(duration: 0.3)) { glow = false }
            }
        }
    }
}

/// What the run changed, with Undo. Counts up as it arrives.
private struct AgentChangesRow: View {
    let changes: AgentChatChanges
    let first: Bool
    let alive: Bool
    let fx: AgentChatFX
    let toggle: () -> Void
    let undo: () -> Void

    @Environment(\.atticDesign) private var design
    @State private var shown: Int?
    @State private var arrived: Bool
    @State private var pop = false

    init(changes: AgentChatChanges, first: Bool, alive: Bool, fx: AgentChatFX, toggle: @escaping () -> Void, undo: @escaping () -> Void) {
        self.changes = changes
        self.first = first
        self.alive = alive
        self.fx = fx
        self.toggle = toggle
        self.undo = undo
        _arrived = State(initialValue: !(first && alive))
    }

    private var undone: Bool { changes.state == .undone }

    private var title: String {
        if undone { return String(localized: "Undone") }
        let count = shown ?? changes.set.count
        return count == 1 ? String(localized: "1 change") : String(localized: "\(count) changes")
    }

    var body: some View {
        let ink = undone ? TasksPanelDesign.toneInk(.meta, tokens: design.tokens).color : design.tokens.ink(.heading).color
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Button(action: toggle) {
                    HStack(spacing: 5) {
                        AgentSparkShape().fill(ink).frame(width: 8.5, height: 8.5)
                            .scaleEffect(pop ? 1.9 : 1)
                            .rotationEffect(.degrees(pop ? -90 : 0))
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(AgentChatStage.space)) } action: { fx.changesStar = $0 }
                        Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(ink)
                        if !undone {
                            Image(systemName: "chevron.down").font(.system(size: 6, weight: .bold))
                                .foregroundStyle(TasksPanelDesign.toneInk(.meta, tokens: design.tokens).color)
                                .rotationEffect(.degrees(changes.isExpanded ? 180 : 0))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(undone)
                if !undone {
                    Button(action: undo) {
                        Text("Undo").font(.system(size: 10, weight: .medium))
                            .foregroundStyle(design.tokens.ink(.heading).color)
                            .padding(.horizontal, 8).frame(height: 20)
                            .background(AgentChatFill.quiet(design), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(changes.state != .ready)
                    .accessibilityIdentifier("agent-chat-undo")
                }
            }
            .frame(height: 28)
            .padding(.leading, 9)
            .padding(.trailing, 5)
            if changes.isExpanded, !undone {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(changes.items) { item in
                        HStack(spacing: 8) {
                            Text(item.title).lineLimit(1).truncationMode(.tail).foregroundStyle(design.tokens.ink(.heading).color)
                            Spacer(minLength: 0)
                            Text(item.detail).foregroundStyle(item.isDelete
                                ? TasksPanelDesign.vivid(design.tokens.ink(.priorityHigh), tokens: design.tokens).color
                                : TasksPanelDesign.toneInk(.date, tokens: design.tokens).color)
                        }
                        .font(.system(size: 10))
                    }
                }
                .padding(.horizontal, 9)
                .padding(.bottom, 6)
            }
        }
        .background { Color.clear.atticRaisedMaterial(cornerRadius: 12, interactive: false) }
        .atticDesignCorners()
        .opacity(arrived ? 1 : 0)
        .offset(y: arrived ? 0 : 8)
        .scaleEffect(arrived ? 1 : 0.955)
        .onReceive(fx.starPop) {
            guard alive else { return }
            pop = true
            withAnimation(.timingCurve(0.3, 1.6, 0.5, 1, duration: 0.56)) { pop = false }
        }
        .task { await appear() }
    }

    private func appear() async {
        guard !arrived else { return }
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.52)) { arrived = true }
        shown = 0
        try? await Task.sleep(for: .seconds(0.18))
        for count in 1...max(1, changes.set.count) {
            try? await Task.sleep(for: .seconds(0.09))
            shown = count
        }
        shown = nil
    }
}

/// A quiet fill for the chat's small buttons, in either appearance.
enum AgentChatFill {
    @MainActor
    static func quiet(_ design: AtticDesignContext) -> Color {
        design.tokens.ink(.heading).color.opacity(0.06)
    }
}
