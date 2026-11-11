import AppKit
import SwiftUI

/// Shows a watched change being made on the real page (the design's
/// `goPage`, `noteAct`, `calAct` and `drawAct`, Accepted 2026-11-06 "Chat
/// with an agent: floating, Chat life alive"): the spark is the pointer, it
/// goes to the island and taps it, the page comes forward through the
/// panel's own page switch, and the change is played in.
///
/// Every change is saved before it is asked to show it. It only presents:
/// a row hidden then grown in, objects veiled under a replay. However a
/// presentation ends (done, the chat closed, the app quitting), nothing
/// stays hidden. With Reduce Motion the page comes forward and the change
/// is simply there.
@MainActor
final class PanelAgentWatcher {
    struct Pace: Equatable {
        /// The design's `moveTo`: to the island 560 ms, to a day 560 ms, to a
        /// new row 420 ms, to a stroke's start 300 ms.
        var toIsland: TimeInterval = 0.56
        var toDay: TimeInterval = 0.56
        var toRow: TimeInterval = 0.42
        var toStroke: TimeInterval = 0.3
        /// After the island's tap, while the page arrives.
        var afterSwitch: TimeInterval = 0.56
        /// After the day's tap, while the agenda moves to it.
        var afterDay: TimeInterval = 0.76
        /// The new event on show before the chat comes back.
        var afterEvent: TimeInterval = 1.0
        /// A stroke draws at 3 ms a point (the drawing's 1.5 ms a pixel), never under 240 ms.
        var strokePerPoint: TimeInterval = 0.003
        var strokeMinimum: TimeInterval = 0.24
        /// The label's fade in, then the sketch on show.
        var labelIn: TimeInterval = 0.36
        var afterSketch: TimeInterval = 0.56
        /// Reduce Motion: how long the change is on show, plainly.
        var hold: TimeInterval = 0.9
        var frame: TimeInterval = 1.0 / 60

        static let instant = Pace(toIsland: 0, toDay: 0, toRow: 0, toStroke: 0, afterSwitch: 0, afterDay: 0,
                                  afterEvent: 0, strokePerPoint: 0, strokeMinimum: 0, labelIn: 0, afterSketch: 0,
                                  hold: 0, frame: 0)
    }

    private weak var chat: AgentChatModel?
    private let noteWriter: AgentNoteWriter
    var pace = Pace()
    var reducesMotion: () -> Bool = { false }
    /// An island item's centre in the panel window's coordinates, and its
    /// tap on the island. Set by the panel controller.
    var islandPoint: (AgentPage) -> CGPoint? = { _ in nil }
    var islandTap: (AgentPage) -> Void = { _ in }
    /// The page on show.
    var currentPage: () -> AgentPage? = { nil }
    /// The Draw page, where it is the Canvas page.
    var drawPage: () -> DrawPageModel? = { AtticDraw.isEnabled ? DrawPageModel.shared : nil }
    let board: AgentWatchBoard

    init(chat: AgentChatModel, noteWriter: AgentNoteWriter, board: AgentWatchBoard = .shared) {
        self.chat = chat
        self.noteWriter = noteWriter
        self.board = board
    }

    private var watching: Bool { chat?.isOpen == true && !Task.isCancelled }
    private var alive: Bool { !reducesMotion() }

    /// The presentation for a saved change, or nil when there is nothing to show.
    func presentation(for action: AgentWatchedAction) -> (() async -> Void)? {
        guard chat?.isOpen == true else { return nil }
        switch action {
        case let .openPage(page):
            return { [self] in await goTo(page) }
        case let .note(id):
            guard let generation = chat?.watchingGeneration else { return nil }
            return noteWriter.presentation(for: id, watching: { [weak chat] in chat?.isWatching(generation) == true },
                                           point: { [weak chat] in chat?.writingAt($0, star: $1) })
        case let .calendarEvent(target):
            guard let occurrence = target.externalID else { return nil }
            // Hidden before the page first draws it, as a note's text is.
            if alive { board.hideEvent(occurrence) }
            return { [self] in await showEvent(occurrence) }
        case let .sketch(canvas, objects):
            guard let draw = drawPage() else { return nil }
            if alive { draw.agentVeil.formUnion(objects) }
            return { [self] in await sketch(objects, on: canvas, draw: draw) }
        }
    }

    // MARK: The page

    /// The design's `goPage`: the spark goes to the island's item, taps it
    /// (the ring, the item pressed), the page switches, the page arrives.
    func goTo(_ page: AgentPage, whileWatching isCurrent: () -> Bool = { true }) async {
        guard watching, isCurrent(), currentPage() != page else { return }
        if alive, let at = islandPoint(page) {
            await move(to: .window(at), for: pace.toIsland)
            guard watching, isCurrent() else { return }
            chat?.watchEffect(.tap(.window(at)))
            islandTap(page)
        }
        guard watching, isCurrent() else { return }
        chat?.openPage?(page)
        await pause(pace.afterSwitch)
    }

    // MARK: Calendar

    /// The design's `calAct`: Calendar forward, the spark picks the day, then
    /// the event's card grows in, pings and bursts.
    private func showEvent(_ occurrence: String) async {
        defer { board.settleEvent(occurrence) }
        await goTo(.calendar)
        guard watching, let day = Self.day(of: occurrence) else { return }
        guard alive else {
            board.pick(day)
            board.settleEvent(occurrence)
            await pause(pace.hold)
            return
        }
        let dayKey = AgentWatchBoard.dayKey(day)
        if let key = await frame(dayKey) {
            let at = AgentWatchRect(rect: key, space: .global).centre
            await move(to: at, for: pace.toDay)
            guard watching else { return }
            chat?.watchEffect(.tap(at))
        }
        board.pick(day)
        await pause(pace.afterDay)
        guard watching else { return }
        // The row takes its place now; its frame is known once laid out.
        let rowKey = AgentWatchBoard.eventKey(occurrence)
        var row = board.frame(rowKey)
        if let row {
            // The design's x of 90 px: the row's start.
            await move(to: .global(CGPoint(x: row.minX + 8, y: row.midY)), for: pace.toRow)
        }
        guard watching else { return }
        board.growEvent(occurrence)
        await pause(0.05)
        row = await frame(rowKey) ?? row
        if let row {
            let landing = AgentWatchPoint.global(CGPoint(x: row.minX + 8, y: row.midY))
            chat?.watchEffect(.ping(AgentWatchRect(rect: row, space: .global), duration: 1.4))
            chat?.watchEffect(.burst(landing, count: 14, speed: 65, ring: 35))
        }
        await pause(pace.afterEvent)
        chat?.watchEffect(.pointer(nil))
    }

    /// An occurrence's day, from its identifier (`id@start`).
    static func day(of occurrence: String, calendar: Calendar = .autoupdatingCurrent) -> DueDay? {
        guard let at = occurrence.split(separator: "@").last, let seconds = TimeInterval(at) else { return nil }
        return DueDay(date: Date(timeIntervalSinceReferenceDate: seconds), calendar: calendar)
    }

    // MARK: Draw

    /// The design's `drawAct`: Draw forward on the canvas, the spark draws
    /// each outline and the arrow, then the text appears with a burst.
    private func sketch(_ objects: [UUID], on canvas: UUID, draw: DrawPageModel) async {
        defer { draw.agentVeil.subtract(objects) }
        await goTo(.draw)
        guard watching else { return }
        if draw.canvasID != canvas { draw.open(canvas) }
        guard alive else {
            draw.agentVeil.subtract(objects)
            await pause(pace.hold)
            return
        }
        // Once the board is laid out on the canvas (a page just switched in,
        // or a canvas just opened, takes a few frames).
        var board: NSView?
        for _ in 0..<30 {
            await frameWait()
            guard watching else { return }
            if let view = draw.board as? NSView, view.window != nil, view.bounds.height > 0 { board = view; break }
        }
        guard let board else { return }
        let palette = DrawPalette(dark: board.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let shown = objects.compactMap(draw.object).sorted(by: DrawPageModel.order)
        let replay = AgentSketchReplay()
        let viewport = draw.viewport
        var toWindow = CGAffineTransform(scaleX: viewport.zoom, y: viewport.zoom)
            .concatenating(CGAffineTransform(translationX: viewport.x, y: viewport.y))
        // Board space runs down from the view's top (`DrawBoardView.boardPoint`);
        // then the view's own space to the window's (flipped or not).
        toWindow = toWindow.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: board.bounds.height))
        let origin = board.convert(CGPoint.zero, to: nil)
        let down = board.convert(CGPoint(x: 0, y: 1), to: nil).y - origin.y
        toWindow = toWindow.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: down, tx: origin.x, ty: origin.y))
        for object in shown {
            switch object.content {
            case .stroke, .shape:
                guard let path = DrawGeometry.path(object), let placed = path.copy(using: &toWindow) else { continue }
                replay.strokes.append(.init(path: placed, colour: Color(cgColor: palette.cgColor(object.style.colour)),
                                            width: DrawGeometry.strokeWidth(object) * viewport.zoom))
            case let .text(text):
                let size = CGFloat(object.style.size.textSize * (object.textScale ?? 1)) * viewport.zoom
                let at = CGPoint(x: object.frame.x, y: object.frame.y).applying(toWindow)
                replay.labels.append(.init(text: text, origin: at, size: size,
                                           colour: Color(cgColor: palette.cgColor(object.style.colour))))
            case .image:
                continue
            }
        }
        chat?.watchEffect(.sketch(replay))
        defer { replay.finished = true }
        for index in replay.strokes.indices {
            guard watching else { return }
            let path = replay.strokes[index].path
            let points = Self.samples(path)
            guard let first = points.first else { continue }
            await move(to: .window(first), for: pace.toStroke)
            let length = zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
            let duration = max(pace.strokeMinimum, Double(length) * pace.strokePerPoint)
            let start = Date()
            var lastStar = start
            while watching {
                let t = duration > 0 ? min(1, Date().timeIntervalSince(start) / duration) : 1
                replay.strokes[index].drawn = CGFloat(t)
                let tip = points[min(points.count - 1, Int(Double(points.count - 1) * t))]
                chat?.watchEffect(.pointer(.window(tip)))
                if Date().timeIntervalSince(lastStar) >= 0.04 {
                    lastStar = Date()
                    if Double.random(in: 0...1) < 0.3 { chat?.watchEffect(.burst(.window(tip), count: 1, speed: 12, ring: 0)) }
                }
                if t >= 1 { break }
                await frameWait()
            }
        }
        guard watching else { return }
        for index in replay.labels.indices {
            let label = replay.labels[index]
            chat?.watchEffect(.burst(.window(CGPoint(x: label.origin.x + label.size, y: label.origin.y)), count: 16, speed: 75, ring: 0))
            let start = Date()
            while watching {
                let t = pace.labelIn > 0 ? min(1, Date().timeIntervalSince(start) / pace.labelIn) : 1
                replay.labels[index].shown = CGFloat(t)
                if t >= 1 { break }
                await frameWait()
            }
        }
        // The objects themselves take over from the replay, at once (both
        // drawn together read as bold).
        draw.agentVeil.subtract(objects)
        replay.finished = true
        await pause(pace.afterSketch)
        chat?.watchEffect(.pointer(nil))
    }

    /// Points along a path, close enough for the spark to follow.
    static func samples(_ path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint, .addLineToPoint: points.append(e.points[0])
            case .addQuadCurveToPoint:
                let a = points.last ?? e.points[0]
                for k in 1...8 {
                    let t = CGFloat(k) / 8
                    let u = 1 - t
                    points.append(CGPoint(x: u * u * a.x + 2 * u * t * e.points[0].x + t * t * e.points[1].x,
                                          y: u * u * a.y + 2 * u * t * e.points[0].y + t * t * e.points[1].y))
                }
            case .addCurveToPoint:
                let a = points.last ?? e.points[0]
                for k in 1...10 {
                    let t = CGFloat(k) / 10
                    let u = 1 - t
                    let x = u * u * u * a.x + 3 * u * u * t * e.points[0].x + 3 * u * t * t * e.points[1].x + t * t * t * e.points[2].x
                    let y = u * u * u * a.y + 3 * u * u * t * e.points[0].y + 3 * u * t * t * e.points[1].y + t * t * t * e.points[2].y
                    points.append(CGPoint(x: x, y: y))
                }
            case .closeSubpath:
                if let first = points.first { points.append(first) }
            @unknown default: break
            }
        }
        return points
    }

    // MARK: Helpers

    /// The design's `moveTo`: the spark heads for a point while this waits.
    private func move(to point: AgentWatchPoint, for seconds: TimeInterval) async {
        chat?.watchEffect(.pointer(point))
        await pause(seconds)
    }

    /// A frame reported by a page, given a few frames to lay out.
    private func frame(_ key: String) async -> CGRect? {
        for _ in 0..<12 {
            if let frame = board.frame(key), frame.width > 0 { return frame }
            await frameWait()
        }
        return nil
    }

    private func frameWait() async {
        if pace.frame > 0 { try? await Task.sleep(for: .seconds(pace.frame)) } else { await Task.yield() }
    }

    /// Waits `seconds`, or less once the chat closes.
    private func pause(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return await Task.yield() }
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, watching {
            try? await Task.sleep(for: .seconds(max(0.001, min(0.05, end.timeIntervalSinceNow))))
        }
    }
}

/// The window the spark flies out to the island in (the design's `goPage`):
/// a see-through, click-through window over the panel, the gap and the
/// island, which draws the chat's alive layer while the spark is past the
/// panel's edge. The stage draws it again once the spark is back.
@MainActor
final class AgentReachWindow {
    /// How far past the panel and the island the layer may draw.
    static let margin: CGFloat = 40

    private(set) var window: NSPanel?

    /// Never moved down from under the menu bar: a frame pushed down there
    /// would put the drawing out of line with the stage.
    private final class Window: NSPanel {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// Draws `fx` over `panel` and `island` (screen frames), with the stage
    /// where `stage` is. False when the stage is not in a window.
    func show(fx: AgentChatFX, stage: NSView, over panel: NSWindow, island: CGRect?) -> Bool {
        guard let stageWindow = stage.window else { return false }
        let stageFrame = stageWindow.convertToScreen(stage.convert(stage.bounds, to: nil))
        var area = stageFrame
        if let island { area = area.union(island) }
        area = area.insetBy(dx: -Self.margin, dy: -Self.margin)
        // Nothing is drawn above the panel's top: the layer stays clear of the menu bar.
        area.size.height = min(area.maxY, stageFrame.maxY) - area.minY
        area = area.integral
        let window = self.window ?? make()
        self.window = window
        window.setFrame(area, display: false)
        // The layer's space runs down from the window's top left.
        let origin = CGPoint(x: stageFrame.minX - area.minX, y: area.maxY - stageFrame.maxY)
        window.contentView = NSHostingView(rootView: AgentChatFXReachLayer(fx: fx, stageOrigin: origin,
                                                                           stageSize: stage.bounds.size))
        if window.parent !== panel {
            window.parent?.removeChildWindow(window)
            panel.addChildWindow(window, ordered: .above)
        }
        // Above the island, which is the panel's child too.
        window.orderFrontRegardless()
        return true
    }

    func hide() {
        guard let window, window.isVisible || window.parent != nil else { return }
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
        window.contentView = nil
    }

    private func make() -> NSPanel {
        let window = Window(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.setAccessibilityElement(false)
        return window
    }
}

