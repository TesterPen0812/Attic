import Combine
import SwiftUI

/// The HTML's easings, for values the chat works out by hand.
enum AgentEase {
    /// A CSS `cubic-bezier` at time `t` (0...1).
    static func curve(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        func bezier(_ a: Double, _ b: Double, _ u: Double) -> Double {
            3 * (1 - u) * (1 - u) * u * a + 3 * (1 - u) * u * u * b + u * u * u
        }
        var u = t
        for _ in 0..<6 {
            let slope = 3 * (1 - u) * (1 - u) * x1 + 6 * (1 - u) * u * (x2 - x1) + 3 * u * u * (1 - x2)
            guard abs(slope) > 0.0001 else { break }
            u -= (bezier(x1, x2, u) - t) / slope
        }
        return bezier(y1, y2, min(max(u, 0), 1))
    }

    /// `cubic-bezier(0.2, 0.8, 0.2, 1)`, the chat's settle.
    static func settle(_ t: Double) -> Double { curve(0.2, 0.8, 0.2, 1, t) }
}

/// The chat's four iris colours (the design's `IRIS`).
enum AgentIris {
    static let blue = Color(red: 122 / 255, green: 134 / 255, blue: 1)
    static let pink = Color(red: 1, green: 120 / 255, blue: 170 / 255)
    static let amber = Color(red: 1, green: 180 / 255, blue: 90 / 255)
    static let teal = Color(red: 90 / 255, green: 220 / 255, blue: 200 / 255)
    static let all = [blue, pink, amber, teal]
    static var underline: Gradient { Gradient(colors: [blue, pink, amber]) }
    /// The two tints of the running line's sweep.
    static func shimmer(over ink: Color) -> (blue: Color, pink: Color) {
        // The pure iris on pale glass reads as the words fading away, so the
        // sweep keeps most of the line's own ink.
        (ink.mix(with: blue, by: 0.55), ink.mix(with: pink, by: 0.55))
    }
    /// The spark's own fill (`ch-iris2`).
    static var spark: Gradient {
        Gradient(stops: [
            .init(color: Color(red: 100 / 255, green: 112 / 255, blue: 1), location: 0),
            .init(color: Color(red: 1, green: 92 / 255, blue: 156 / 255), location: 0.38),
            .init(color: Color(red: 1, green: 168 / 255, blue: 70 / 255), location: 0.72),
            .init(color: Color(red: 60 / 255, green: 205 / 255, blue: 185 / 255), location: 1)
        ])
    }
}

/// The word being written, reported by the reply's renderer (which may draw
/// off the main actor) and read by the spark.
final class AgentWordProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (paragraph: Int, rect: CGRect, time: Date)?

    func report(paragraph: Int, rect: CGRect, time: Date) {
        lock.withLock { value = (paragraph, rect, time) }
    }

    var latest: (paragraph: Int, rect: CGRect, time: Date)? { lock.withLock { value } }
}

/// The alive layer: one spark, its particles, the light over the rows and the
/// flying chips, in points. Everything draws in one Canvas above the thread,
/// never in a row, so a row's body gains no work. It exists only while the
/// stage is on screen, and stops asking for frames once nothing moves.
@MainActor
final class AgentChatFX: ObservableObject {
    /// Where one day's chips land: every run has its own strip, and a strip's
    /// day can change within a run.
    struct WeekSlot: Hashable {
        var week: UUID
        var day: Date
    }

    /// Nothing is moving: the timelines pause until `wake()`.
    @Published private(set) var isIdle = false
    /// The spark is out past the stage's edge (to the island and back):
    /// meanwhile a window over the panel and the island draws this layer in
    /// the stage's place, so the flight and the island's tap ring show whole.
    @Published private(set) var reachesOut = false
    /// A window can draw the layer past the stage (the panel's can; a bare
    /// stage cannot, and its spark simply stops at the edge).
    var canReachOut = false
    /// The stage's size, as last drawn.
    private(set) var stageSize: CGSize = .zero
    private var reachTurn = 0
    /// The spark reached the changes row: its ✦ answers.
    let starPop = PassthroughSubject<Void, Never>()

    // What the stage knows. Written by views, read on each frame.
    var acting = false { didSet { if acting != oldValue { wake() } } }
    var needsYou = false { didSet { if needsYou != oldValue { wake() } } }
    var emptyThread = true { didSet { if emptyThread != oldValue { wake() } } }
    var dark = false
    var toolSlot: CGRect?
    var changesStar: CGRect?
    var weekSlots: [WeekSlot: CGRect] = [:]
    var composerFrame: CGRect?
    var askedFrame: CGRect?
    /// Where the current exchange starts, in the stage's space.
    var turnTop: CGFloat?
    /// Where the blur's wipe opens from; the colour opens from there too.
    var wipeOrigin: CGPoint?
    /// The stage's origin in the panel's global space, for frames the pages report.
    var stageOrigin: CGPoint = .zero
    var paragraphFrames: [Int: CGRect] = [:]
    let word = AgentWordProbe()

    private struct Particle {
        enum Kind { case star, dust, gather }
        var kind: Kind
        var x, y, vx, vy, gravity: CGFloat
        var life, age: Double
        var size, alpha: CGFloat
        var colour: Color
        var spin = 0.0
        var rotation = 0.0
        /// `gather` only: where it settles.
        var homeX: CGFloat = 0
        var homeY: CGFloat = 0
    }

    private struct Ring {
        var x, y, radius: CGFloat
        var duration, age: Double
        var colour: Color
    }

    struct Flight {
        var title: String
        var from, to: CGPoint
        var delay: Double
        var age = 0.0
        var onLand: (() -> Void)?
    }

    private struct Scan {
        var rows: [CGRect]
        var age = 0.0
    }

    private struct Spark {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var scale: CGFloat = 0
        var pinch: CGFloat = 0.2
        var on = false
    }

    private var particles: [Particle] = []
    private var rings: [Ring] = []
    private var flights: [Flight] = []
    private var scans: [Scan] = []
    private var spark = Spark()
    private var landing = false
    private var last: Date?
    private var time = 0.0
    private var ember = 0.0
    private(set) var energy = 0.0
    private(set) var flash = 0.0
    private(set) var angle = 0.0
    /// What each step did on screen, so Undo can run it backwards.
    private var history: [UUID: (flights: [Flight], rows: [CGRect])] = [:]

    func wake() {
        if isIdle { isIdle = false }
        last = nil
    }

    /// The stage has just opened: nothing left over from last time moves.
    func clearLive() {
        particles = []
        rings = []
        flights = []
        scans = []
        pings = []
        pointer = nil
        spark = Spark()
        landing = false
        wake()
    }

    /// The chat has just opened from the ✦.
    func open(at star: CGPoint) {
        clearLive()
        addFlash(0.9)
        // No ring and no stars: a burst from the ✦ spreads as a dotted halo
        // around it while the composer grows (screen 9, item 22). The colour
        // and the blur are the opening; the first ember waits a moment.
        ember = Self.firstEmber
    }

    private static let firstEmber = 1.2

    #if DEBUG
    /// Test seam: how much is alive.
    var liveCount: Int { particles.count + rings.count + flights.count + scans.count }
    var ringCount: Int { rings.count }
    /// The colour's circle, as a scale of its full radius, last drawn.
    var lastAuraScale: CGFloat?
    #endif

    // MARK: Spawning (design px halved)

    private func rnd(_ a: Double, _ b: Double) -> Double { Double.random(in: min(a, b)...max(a, b)) }
    private var irisColour: Color { AgentIris.all.randomElement() ?? AgentIris.blue }

    func star(_ x: CGFloat, _ y: CGFloat, vx: Double? = nil, vy: Double? = nil, gravity: Double = 0, life: Double? = nil,
              wait: Double = 0, size: Double? = nil, alpha: Double = 0.9) {
        guard particles.count < 900 else { return }
        particles.append(Particle(kind: .star, x: x, y: y, vx: vx ?? rnd(-20, 20), vy: vy ?? rnd(-30, -5), gravity: gravity,
                                  life: life ?? rnd(0.6, 1.2), age: -wait, size: size ?? rnd(1.5, 4), alpha: alpha,
                                  colour: irisColour, spin: rnd(-3, 3), rotation: rnd(0, 3)))
    }

    func burst(_ x: CGFloat, _ y: CGFloat, count: Int = 18, speed: Double = 95, life: ClosedRange<Double> = 0.45...0.9) {
        for index in 0..<count {
            let angle = Double(index) / Double(count) * 6.283 + rnd(-0.2, 0.2)
            let velocity = rnd(speed * 0.4, speed)
            star(x, y, vx: cos(angle) * velocity, vy: sin(angle) * velocity, gravity: 30, life: rnd(life.lowerBound, life.upperBound), size: rnd(1.5, 4.5))
        }
        wake()
    }

    func ring(_ x: CGFloat, _ y: CGFloat, radius: CGFloat = 45, duration: Double = 0.6) {
        rings.append(Ring(x: x, y: y, radius: radius, duration: duration, age: 0, colour: Bool.random() ? AgentIris.blue : AgentIris.pink))
        wake()
    }

    func dust(_ rect: CGRect, count: Int = 200) {
        let grey = dark ? Color(white: 0.82) : Color(red: 60 / 255, green: 62 / 255, blue: 66 / 255)
        for _ in 0..<count {
            let u = Double.random(in: 0...1)
            particles.append(Particle(kind: .dust, x: rect.minX + u * rect.width, y: rect.minY + rnd(0.15, 0.85) * rect.height,
                                      vx: rnd(10, 55), vy: rnd(-45, -6), gravity: -9, life: rnd(0.6, 1.3), age: -u * 0.32,
                                      size: rnd(0.6, 1.5), alpha: rnd(0.35, 0.8),
                                      colour: Double.random(in: 0...1) < 0.2 ? irisColour : grey))
        }
        wake()
    }

    /// Dust running backwards: it comes in from around a row and settles.
    private func gather(_ rect: CGRect, count: Int = 120) {
        let grey = dark ? Color(white: 0.82) : Color(red: 60 / 255, green: 62 / 255, blue: 66 / 255)
        for _ in 0..<count {
            let u = Double.random(in: 0...1)
            let homeX = rect.minX + u * rect.width, homeY = rect.minY + rnd(0.15, 0.85) * rect.height
            particles.append(Particle(kind: .gather, x: homeX + rnd(14, 60), y: homeY + rnd(-45, 12), vx: 0, vy: 0, gravity: 0,
                                      life: rnd(0.45, 0.8), age: -u * 0.2, size: rnd(0.6, 1.5), alpha: rnd(0.35, 0.8),
                                      colour: Double.random(in: 0...1) < 0.2 ? irisColour : grey, homeX: homeX, homeY: homeY))
        }
        wake()
    }

    /// A trail of stars along a curve (the sent message's rise).
    func comet(from a: CGPoint, to b: CGPoint) {
        for index in 0..<34 {
            let u = Double(index) / 33
            let cx = (a.x + b.x) / 2 + 45, cy = (a.y + b.y) / 2
            let x = (1 - u) * (1 - u) * a.x + 2 * (1 - u) * u * cx + u * u * b.x
            let y = (1 - u) * (1 - u) * a.y + 2 * (1 - u) * u * cy + u * u * b.y
            star(x + rnd(-2.5, 2.5), y + rnd(-2.5, 2.5), vx: rnd(-7, 7), vy: rnd(-4, 11), life: rnd(0.35, 0.7),
                 wait: u * 0.34, size: rnd(1.25, 3.25))
        }
        wake()
    }

    func addFlash(_ amount: Double) {
        flash = min(1, flash + amount)
        wake()
    }

    /// A keystroke's small star, near the caret.
    func keystroke(count: Int) {
        guard let frame = composerFrame else { return }
        flash = min(0.5, flash + 0.1)
        star(frame.minX + 13 + min(CGFloat(count) * 5.5, frame.width - 26), frame.minY + 8,
             vx: rnd(-11, 11), vy: rnd(-35, -14), life: rnd(0.4, 0.8), size: rnd(1.25, 3))
        wake()
    }

    /// The light passes down the rows the agent reads.
    func scan(_ rows: [CGRect]) {
        guard !rows.isEmpty else { return }
        scans.append(Scan(rows: rows))
        wake()
    }

    /// Chips leave their rows 240 ms apart and land on `targets`.
    func fly(step: UUID, _ moves: [(title: String, row: CGRect?, to: CGPoint, onLand: () -> Void)]) {
        var made: [Flight] = []
        for (index, move) in moves.enumerated() {
            let row = move.row ?? CGRect(x: 40, y: 150 + CGFloat(index) * 35, width: 250, height: 28)
            let from = CGPoint(x: row.minX + 95, y: row.minY + min(row.height, 29) / 2)
            made.append(Flight(title: move.title, from: from, to: move.to, delay: Double(index) * 0.24, onLand: move.onLand))
        }
        flights += made
        history[step, default: ([], [])].flights = made
        wake()
    }

    func turnToDust(step: UUID, _ rows: [CGRect]) {
        rows.forEach { dust($0, count: 240) }
        history[step, default: ([], [])].rows = rows
    }

    /// Runs what `steps` did backwards: chips go home, dust settles.
    func undo(steps: [UUID]) {
        for step in steps.reversed() {
            guard let done = history.removeValue(forKey: step) else { continue }
            for (index, flight) in done.flights.reversed().enumerated() {
                flights.append(Flight(title: flight.title, from: flight.to, to: flight.from, delay: Double(index) * 0.11))
            }
            done.rows.forEach { gather($0) }
        }
        addFlash(0.4)
    }

    /// The spark flies to the changes row's ✦ and hands the work over.
    func landOnChanges() {
        landing = true
        wake()
    }

    var sparkPoint: CGPoint { CGPoint(x: spark.x, y: spark.y) }

    /// Where a watched note edit is being written, and when it got there.
    private var writing: (point: CGPoint, time: Date)?

    /// The spark is the writing point in a note; a star now and then.
    func write(at point: CGPoint, star: Bool) {
        writing = (point, Date())
        if star { self.star(point.x, point.y, vy: rnd(-20, -5), life: rnd(0.3, 0.6), size: rnd(1, 2.25)) }
        wake()
    }

    // MARK: Watching (the design's `fx.act`, `tap`, `ping`, `drawAct`)

    /// Where the spark goes as the agent's pointer, until let go.
    private var pointer: CGPoint?
    private struct Ping {
        var rect: CGRect
        var age = 0.0
        var duration: Double
        /// A hover ping fades out from its peak; a landing holds it.
        var holds: Bool
    }
    private var pings: [Ping] = []
    private var sketches: [(replay: AgentSketchReplay, transform: CGAffineTransform)] = []

    func point(at point: CGPoint?) {
        pointer = point
        if let point { reach(toward: point) }
        wake()
    }

    /// The design's `tap`: a ring of 40 px in 0.42 s and seven stars.
    func tap(at point: CGPoint) {
        reach(toward: point)
        ring(point.x, point.y, radius: 20, duration: 0.42)
        burst(point.x, point.y, count: 7, speed: 35)
    }

    // MARK: Past the stage's edge

    /// How far in from the stage's edge the spark is drawn whole (its glyph,
    /// glow and orbiting dots).
    static let reachMargin: CGFloat = 24

    private var stageBounds: CGRect { CGRect(origin: .zero, size: stageSize) }

    /// Heading for a point past the edge: the reach window takes over first.
    private func reach(toward point: CGPoint) {
        guard canReachOut, !reachesOut, stageSize != .zero,
              !stageBounds.insetBy(dx: Self.reachMargin, dy: Self.reachMargin).contains(point) else { return }
        reachTurn += 1
        reachesOut = true
    }

    /// Back on the stage, whatever happens: the stage draws again.
    func endReach() {
        reachTurn += 1
        if reachesOut { reachesOut = false }
        wake()
    }

    /// Anything still drawn past the edge: the pointer's goal, the spark,
    /// a ring or a particle.
    private var anythingOut: Bool {
        let bounds = stageBounds
        let inner = bounds.insetBy(dx: Self.reachMargin, dy: Self.reachMargin)
        if let pointer, !inner.contains(pointer) { return true }
        if spark.on, !inner.contains(CGPoint(x: spark.x, y: spark.y)) { return true }
        if rings.contains(where: { !bounds.contains(CGRect(x: $0.x - $0.radius, y: $0.y - $0.radius,
                                                           width: $0.radius * 2, height: $0.radius * 2)) }) { return true }
        return particles.contains { !bounds.contains(CGPoint(x: $0.x, y: $0.y)) }
    }

    /// A row lit up: the design's `ping` (a landed card, held) or the hover's.
    func ping(_ rect: CGRect, duration: Double, holds: Bool) {
        pings.append(Ping(rect: rect, duration: duration, holds: holds))
        wake()
    }

    /// A sketch drawn in over Draw; its paths are in window coordinates and
    /// `transform` takes them to this layer's.
    func sketch(_ replay: AgentSketchReplay, transform: CGAffineTransform) {
        sketches.append((replay, transform))
        wake()
    }

    #if DEBUG
    var pointerGoal: CGPoint? { pointer }
    var pingCount: Int { pings.count }
    #endif

    // MARK: Frames

    private struct Goal {
        var x, y, scale, pinch: CGFloat
        var kind: Kind
        enum Kind { case land, need, write, tool }
    }

    private func goal() -> Goal? {
        if landing {
            if let star = changesStar { return Goal(x: star.midX, y: star.midY, scale: 0.5, pinch: 0.06, kind: .land) }
            landing = false
        }
        guard acting || needsYou else { return nil }
        if let writing, Date().timeIntervalSince(writing.time) < 0.25 {
            return Goal(x: writing.point.x, y: writing.point.y, scale: 0.44, pinch: 0.12, kind: .write)
        }
        if let pointer {
            return Goal(x: pointer.x, y: pointer.y, scale: 0.5, pinch: 0.16, kind: .tool)
        }
        if needsYou, let frame = composerFrame {
            return Goal(x: frame.maxX - 23, y: frame.minY + 22 + sin(time * 3.2) * 2, scale: 0.68,
                        pinch: 0.55 + 0.2 * sin(time * 3.2), kind: .need)
        }
        if let latest = word.latest, Date().timeIntervalSince(latest.time) < 0.25, let frame = paragraphFrames[latest.paragraph] {
            return Goal(x: frame.minX + latest.rect.maxX + 7.5, y: frame.minY + latest.rect.midY, scale: 0.44, pinch: 0.12, kind: .write)
        }
        if let slot = toolSlot {
            return Goal(x: slot.midX, y: slot.midY, scale: 0.62, pinch: 0.34 + 0.2 * sin(time * 4), kind: .tool)
        }
        return nil
    }

    /// One frame. Called while drawing; it writes nothing a view observes.
    func advance(to date: Date) {
        let dt = last.map { min(0.12, max(0.001, date.timeIntervalSince($0))) } ?? 0.016
        last = date
        time += dt
        let energyGoal = needsYou ? 0.72 : acting ? 1 : 0.16
        energy += (energyGoal - energy) * (1 - exp(-dt * 3.2))
        flash *= exp(-dt * 2.6)
        angle = (angle + dt * (needsYou ? 90 : 170)).truncatingRemainder(dividingBy: 360)
        moveSpark(dt)
        if emptyThread, let frame = composerFrame {
            ember -= dt
            if ember <= 0 {
                ember = rnd(0.32, 0.8)
                star(frame.minX + rnd(0, frame.width), frame.minY - 17, vx: rnd(-4, 4), vy: rnd(-23, -9),
                     life: rnd(1.4, 2.6), size: rnd(1.25, 3), alpha: 0.55)
            }
        }
        particles = particles.compactMap { particle in
            var p = particle
            p.age += dt
            guard p.age >= 0 else { return p }
            guard p.age < p.life else { return nil }
            if p.kind == .gather {
                let k = 1 - exp(-dt * 9)
                p.x += (p.homeX - p.x) * k
                p.y += (p.homeY - p.y) * k
            } else {
                p.vy += p.gravity * dt
                p.x += p.vx * dt
                p.y += p.vy * dt
                p.vx *= 0.985
            }
            p.rotation += p.spin * dt
            return p
        }
        rings = rings.compactMap { ring in
            var r = ring
            r.age += dt
            return r.age < r.duration ? r : nil
        }
        pings = pings.compactMap { ping in
            var p = ping
            p.age += dt
            return p.age < p.duration ? p : nil
        }
        sketches.removeAll { $0.replay.finished }
        scans = scans.compactMap { scan in
            var s = scan
            s.age += dt
            return s.age < Self.scanLife ? s : nil
        }
        var landed: [Flight] = []
        flights = flights.compactMap { flight in
            var f = flight
            f.age += dt
            if f.age - f.delay >= Self.flightLife {
                landed.append(f)
                return nil
            }
            return f
        }
        for flight in landed {
            burst(flight.to.x, flight.to.y, count: 10, speed: 55)
            ring(flight.to.x, flight.to.y, radius: 23, duration: 0.45)
        }
        if !landed.isEmpty {
            // Off the frame: a landing changes the week strip's state.
            let actions = landed.compactMap(\.onLand)
            DispatchQueue.main.async { actions.forEach { $0() } }
        }
        if reachesOut, !anythingOut {
            // Off the frame, unless it has gone out again since.
            let turn = reachTurn
            DispatchQueue.main.async { [weak self] in
                guard let self, self.reachTurn == turn else { return }
                self.endReach()
            }
        }
        let busy = acting || needsYou || spark.on || landing || emptyThread || !particles.isEmpty || !rings.isEmpty
            || !flights.isEmpty || !scans.isEmpty || !pings.isEmpty || !sketches.isEmpty || pointer != nil
            || abs(energy - energyGoal) > 0.01 || flash > 0.01
        if !busy, !isIdle { DispatchQueue.main.async { [weak self] in self?.isIdle = true } }
    }

    private func moveSpark(_ dt: Double) {
        guard let goal = goal() else {
            if spark.on {
                spark.scale += (0 - spark.scale) * (1 - exp(-dt * 12))
                if spark.scale < 0.03 { spark.on = false }
            }
            return
        }
        if !spark.on {
            spark = Spark(x: goal.x, y: goal.y, scale: 0, pinch: goal.pinch, on: true)
            burst(goal.x, goal.y, count: 10, speed: 45)
        }
        let rate: Double = goal.kind == .write ? 26 : 11
        let k = 1 - exp(-dt * rate)
        let oldX = spark.x, oldY = spark.y
        spark.x += (goal.x - spark.x) * k
        spark.y += (goal.y - spark.y) * k
        spark.scale += (goal.scale - spark.scale) * (1 - exp(-dt * 12))
        spark.pinch += (goal.pinch - spark.pinch) * (1 - exp(-dt * 8))
        let speed = hypot(spark.x - oldX, spark.y - oldY) / dt
        if speed > 60, Double.random(in: 0...1) < 0.7 {
            star(spark.x + rnd(-2, 2), spark.y + rnd(-2, 2), vx: rnd(-8, 8), vy: rnd(-8, 8), life: rnd(0.3, 0.6),
                 size: rnd(1, 2.5), alpha: 0.7)
        }
        if goal.kind == .land, hypot(goal.x - spark.x, goal.y - spark.y) < 3.5 {
            landing = false
            spark.on = false
            spark.scale = 0
            burst(goal.x, goal.y, count: 26, speed: 105)
            ring(goal.x, goal.y, radius: 60, duration: 0.7)
            flash = 0.85
            let pop = starPop
            DispatchQueue.main.async { pop.send() }
        }
    }

    // MARK: Drawing

    static let scanLife = 1.5 + 0.1
    static let flightLife = 0.82

    func draw(in context: inout GraphicsContext, size: CGSize) {
        stageSize = size
        for scan in scans { drawScan(scan, in: &context, width: size.width) }
        for ring in rings {
            let u = ring.age / ring.duration
            let radius = ring.radius * (1 - pow(1 - u, 3))
            context.stroke(Path(ellipseIn: CGRect(x: ring.x - radius, y: ring.y - radius, width: radius * 2, height: radius * 2)),
                           with: .color(ring.colour.opacity(0.5 * (1 - u))), lineWidth: 1.25 * (1 - u) + 0.25)
        }
        for particle in particles where particle.age >= 0 {
            let u = particle.age / particle.life
            let alpha = particle.alpha * (1 - u) * min(1, particle.age * 12)
            if particle.kind == .star {
                let side = particle.size * (1 - u * 0.5)
                let path = Self.miniStar(side).applying(CGAffineTransform(rotationAngle: particle.rotation)
                    .concatenating(CGAffineTransform(translationX: particle.x, y: particle.y)))
                context.fill(path, with: .color(particle.colour.opacity(alpha)))
            } else {
                context.fill(Path(CGRect(x: particle.x, y: particle.y, width: particle.size, height: particle.size)),
                             with: .color(particle.colour.opacity(alpha)))
            }
        }
        for flight in flights where flight.age >= flight.delay { drawChip(flight, in: &context) }
        for ping in pings { drawPing(ping, in: &context) }
        for sketch in sketches { drawSketch(sketch.replay, transform: sketch.transform, in: &context) }
        drawSpark(in: &context)
    }

    /// The design's ping: an iris wash with a rim, 12 pt round.
    private func drawPing(_ ping: Ping, in context: inout GraphicsContext) {
        let t = ping.age / ping.duration
        let opacity = ping.holds ? (t < 0.2 ? t / 0.2 : t < 0.6 ? 1 : (1 - t) / 0.4)
                                 : (t < 0.25 ? t / 0.25 : (1 - t) / 0.75)
        let rect = ping.holds ? ping.rect.insetBy(dx: 2, dy: 1) : ping.rect.insetBy(dx: 3, dy: 1.5)
        let shape = Path(roundedRect: rect, cornerRadius: 12, style: .continuous)
        var layer = context
        layer.opacity = max(0, min(1, opacity))
        let strong = ping.holds ? 0.24 : 0.3
        layer.fill(shape, with: .linearGradient(Gradient(colors: [AgentIris.blue.opacity(strong), AgentIris.pink.opacity(strong / 2)]),
                                                startPoint: CGPoint(x: rect.minX, y: rect.midY),
                                                endPoint: CGPoint(x: rect.maxX, y: rect.midY)))
        layer.stroke(Path(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 11.25, style: .continuous),
                     with: .color(AgentIris.blue.opacity(0.45)), lineWidth: 1.5)
    }

    /// The sketch so far: each stroke drawn up to where the spark is, then
    /// the labels rising 3 pt as they fade in.
    private func drawSketch(_ replay: AgentSketchReplay, transform: CGAffineTransform, in context: inout GraphicsContext) {
        for stroke in replay.strokes where stroke.drawn > 0 {
            let path = Path(stroke.path).applying(transform).trimmedPath(from: 0, to: stroke.drawn)
            context.stroke(path, with: .color(stroke.colour),
                           style: StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round))
        }
        for label in replay.labels where label.shown > 0 {
            var layer = context
            layer.opacity = Double(label.shown)
            let at = label.origin.applying(transform)
            layer.draw(Text(label.text).font(.system(size: label.size)).foregroundColor(label.colour),
                       at: CGPoint(x: at.x, y: at.y + 3 * (1 - label.shown)), anchor: .topLeading)
        }
    }

    private func drawScan(_ scan: Scan, in context: inout GraphicsContext, width: CGFloat) {
        guard let first = scan.rows.first, let lastRow = scan.rows.last else { return }
        let span = max(1, lastRow.maxY - first.minY)
        for row in scan.rows {
            let u = (row.minY - first.minY) / span
            let t = (scan.age - u * 1.26) / (1.5 - u * 0.3)
            guard t > 0, t < 1 else { continue }
            let opacity = t < 0.16 ? t / 0.16 : t < 0.4 ? 1 - 0.45 * (t - 0.16) / 0.24 : 0.55 * (1 - (t - 0.4) / 0.6)
            let rect = row.insetBy(dx: 3, dy: 1.5)
            let shape = Path(roundedRect: rect, cornerRadius: 13, style: .continuous)
            context.fill(shape, with: .linearGradient(
                Gradient(stops: [.init(color: AgentIris.blue.opacity(0.24 * opacity), location: 0),
                                 .init(color: AgentIris.pink.opacity(0.14 * opacity), location: 0.6),
                                 .init(color: AgentIris.amber.opacity(0.06 * opacity), location: 1)]),
                startPoint: CGPoint(x: rect.minX, y: rect.midY), endPoint: CGPoint(x: rect.maxX, y: rect.midY)))
            context.stroke(shape, with: .color(AgentIris.blue.opacity(0.3 * opacity)), lineWidth: 0.75)
        }
        let u = scan.age / 1.36
        guard u < 1 else { return }
        let y = first.minY + span * u
        let opacity = u < 0.08 ? u / 0.08 : u > 0.92 ? (1 - u) / 0.08 : 1
        let bar = CGRect(x: 9, y: y, width: width - 18, height: 1.5)
        var glow = context
        glow.addFilter(.blur(radius: 5.5))
        glow.fill(Path(bar.insetBy(dx: 0, dy: -3.5)), with: .color(AgentIris.blue.opacity(0.3 * opacity)))
        context.fill(Path(roundedRect: bar, cornerRadius: 1), with: .linearGradient(
            Gradient(stops: [.init(color: AgentIris.blue.opacity(0), location: 0),
                             .init(color: AgentIris.blue.opacity(0.9 * opacity), location: 0.33),
                             .init(color: AgentIris.pink.opacity(0.9 * opacity), location: 0.66),
                             .init(color: AgentIris.pink.opacity(0), location: 1)]),
            startPoint: CGPoint(x: bar.minX, y: y), endPoint: CGPoint(x: bar.maxX, y: y)))
    }

    private func drawChip(_ flight: Flight, in context: inout GraphicsContext) {
        let t = min(1, (flight.age - flight.delay) / Self.flightLife)
        let u = AgentEase.curve(0.45, 0.05, 0.3, 1, t)
        let a = flight.from, b = flight.to
        let cx = (a.x + b.x) / 2 + 35, cy = min(a.y, b.y) - 60
        let x = (1 - u) * (1 - u) * a.x + 2 * (1 - u) * u * cx + u * u * b.x
        let y = (1 - u) * (1 - u) * a.y + 2 * (1 - u) * u * cy + u * u * b.y
        let scale = 1 - 0.9 * pow(u, 2.2)
        let text = context.resolve(Text(flight.title).font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(dark ? Color(white: 0.96) : Color(red: 29 / 255, green: 29 / 255, blue: 31 / 255)))
        let size = text.measure(in: CGSize(width: 240, height: 40))
        var chip = context
        chip.opacity = u > 0.94 ? 0.4 : 1
        chip.translateBy(x: x, y: y)
        chip.rotate(by: .degrees(sin(u * .pi) * -6))
        chip.scaleBy(x: scale, y: scale)
        let rect = CGRect(x: -size.width / 2 - 9, y: -size.height / 2 - 4.5, width: size.width + 18, height: size.height + 9)
        let shape = Path(roundedRect: rect, cornerRadius: 11, style: .continuous)
        var shadowed = chip
        shadowed.addFilter(.shadow(color: Color(red: 60 / 255, green: 60 / 255, blue: 120 / 255).opacity(0.2), radius: 7.5, y: 6))
        shadowed.fill(shape, with: .color(dark ? Color(white: 0.16).opacity(0.9) : Color.white.opacity(0.86)))
        chip.stroke(shape, with: .color(Color(red: 185 / 255, green: 189 / 255, blue: 191 / 255).opacity(0.7)), lineWidth: 0.5)
        chip.draw(text, at: .zero)
    }

    private func drawSpark(in context: inout GraphicsContext) {
        guard spark.on, spark.scale > 0.02 else { return }
        let tool = !needsYou && !landing && toolSlot != nil && word.latest.map { Date().timeIntervalSince($0.time) >= 0.25 } ?? true
        var layer = context
        layer.translateBy(x: spark.x, y: spark.y)
        layer.scaleBy(x: spark.scale, y: spark.scale)
        let path = Self.sparkPath(radius: 10, pinch: spark.pinch, rotation: time * (tool ? 1.8 : 0.6), wobble: 0.09, time: time)
        var glow = layer
        glow.addFilter(.shadow(color: AgentIris.blue.opacity(0.6), radius: 3.5))
        glow.fill(path, with: .linearGradient(AgentIris.spark, startPoint: CGPoint(x: -10, y: -10), endPoint: CGPoint(x: 10, y: 10)))
        guard tool else { return }
        for index in 0..<2 {
            let a = time * 4.2 + Double(index + 1) * 3.14
            let centre = CGPoint(x: cos(a) * 15.5, y: sin(a) * 7.5 * (index == 0 ? 1 : -1))
            let radius: CGFloat = index == 0 ? 1.7 : 1.4
            layer.fill(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)),
                       with: .color(index == 0 ? AgentIris.pink : AgentIris.blue))
        }
    }

    /// The design's `sparkPath`: four points, pinched by `pinch`.
    static func sparkPath(radius: Double, pinch: Double, rotation: Double, wobble: Double, time: Double) -> Path {
        func point(_ index: Int) -> CGPoint {
            let a = rotation + Double(index) * 1.5708
            let r = radius * (1 + wobble * sin(time * 5 + Double(index) * 1.7))
            return CGPoint(x: cos(a) * r, y: sin(a) * r)
        }
        let control = radius * (0.13 + 1.27 * pinch)
        var path = Path()
        path.move(to: point(0))
        for index in 0..<4 {
            let a = rotation + Double(index) * 1.5708 + 0.7854
            path.addQuadCurve(to: point(index + 1), control: CGPoint(x: cos(a) * control, y: sin(a) * control))
        }
        path.closeSubpath()
        return path
    }

    private static func miniStar(_ s: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -s))
        let k = s * 0.14
        path.addQuadCurve(to: CGPoint(x: s, y: 0), control: CGPoint(x: k, y: -k))
        path.addQuadCurve(to: CGPoint(x: 0, y: s), control: CGPoint(x: k, y: k))
        path.addQuadCurve(to: CGPoint(x: -s, y: 0), control: CGPoint(x: -k, y: k))
        path.addQuadCurve(to: CGPoint(x: 0, y: -s), control: CGPoint(x: -k, y: -k))
        return path
    }

    /// The soft glow that rises from the bottom while the agent works.
    func drawAura(in context: inout GraphicsContext, size: CGSize, reveal: CGFloat) {
        let e = min(1.25, energy + flash)
        let blobs: [(Double, Double, Double, Double, Double)] = [
            (0.18, 0.9, 0.7, 0.5, 0), (0.52, 0.98, 0.5, 0.8, 2), (0.84, 0.9, 0.9, 0.4, 4), (0.4, 0.8, 0.6, 0.6, 5.2)
        ]
        // No colour before the wipe starts, and none outside its circle.
        guard let origin = wipeOrigin, reveal > 0 else { return }
        let clip: AgentChatWipe? = reveal < 1 ? AgentChatWipe(origin: origin, size: size) : nil
        #if DEBUG
        lastAuraScale = clip?.scale(reveal: reveal) ?? 1
        #endif
        context.drawLayer { layer in
            for (index, blob) in blobs.enumerated() {
                let (bx, by, sx, sy, phase) = blob
                let x = size.width * (bx + 0.2 * sin(time * sx * 0.8 + phase))
                let y = size.height * (by + 0.08 - 0.3 * e * (0.55 + 0.45 * sin(time * sy * 0.5 + phase)))
                let radius = size.width * (0.34 + 0.34 * e)
                let colour = AgentIris.all[index]
                layer.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                    Gradient(colors: [colour.opacity(0.3 * min(1, e + 0.12)), colour.opacity(0)]),
                    center: CGPoint(x: x, y: y), startRadius: 0, endRadius: radius))
            }
            // The colour opens with the blur: the same circle, the same rim.
            guard let clip else { return }
            let radius = clip.fullRadius * clip.scale(reveal: reveal)
            layer.blendMode = .destinationIn
            layer.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                Gradient(stops: [.init(color: .black, location: 0),
                                 .init(color: .black, location: 1 - AgentChatWipe.feather),
                                 .init(color: .clear, location: 1)]),
                center: clip.origin, startRadius: 0, endRadius: max(0.5, radius)))
        }
    }
}

/// The particles, light, chips and spark: above everything, taking no clicks.
struct AgentChatFXLayer: View {
    @ObservedObject var fx: AgentChatFX

    var body: some View {
        // While the spark is out past the edge, the reach window draws it all.
        if !fx.reachesOut {
            TimelineView(.animation(minimumInterval: 1 / 60, paused: fx.isIdle)) { timeline in
                Canvas { context, size in
                    fx.advance(to: timeline.date)
                    fx.draw(in: &context, size: size)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// The same layer in the reach window, which spans the panel and the
/// island: the stage's drawing, moved to where the stage sits in it.
struct AgentChatFXReachLayer: View {
    @ObservedObject var fx: AgentChatFX
    /// The stage's top left in this layer.
    let stageOrigin: CGPoint
    let stageSize: CGSize

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: fx.isIdle)) { timeline in
            Canvas { context, _ in
                fx.advance(to: timeline.date)
                context.translateBy(x: stageOrigin.x, y: stageOrigin.y)
                fx.draw(in: &context, size: stageSize)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The aura, under the thread. Its circle is the blur's: `reveal` is the
/// same animated value, so on every frame of the wipe the colour is drawn
/// where the blur is, whatever the timeline's own rate.
struct AgentChatAuraLayer: View, Animatable {
    @ObservedObject var fx: AgentChatFX
    var reveal: CGFloat

    var animatableData: CGFloat {
        get { reveal }
        set { reveal = newValue }
    }

    var body: some View {
        let reveal = reveal
        TimelineView(.animation(minimumInterval: 1 / 30, paused: fx.isIdle)) { _ in
            Canvas { context, size in
                fx.drawAura(in: &context, size: size, reveal: reveal)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
