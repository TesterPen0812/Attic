import AppKit
import Combine
import SwiftUI

/// How far the chat's glass clears while the agent works on a real page: the
/// design's `watch(n)` (Accepted 2026-11-06, "open means watching"). The blur
/// goes 10 → 3 → 0 in the drawing (5 → 1.5 → 0 here, at the panel's scale),
/// its tint with it; at `watching` the thread is gone and the live label
/// sits over the composer.
enum AgentWatchLevel: Int, Comparable, Sendable {
    /// The chat as it is: the full blur.
    case none = 0
    /// Rows being read or moved on Tasks show through a thin blur.
    case glance = 1
    /// The agent works on the page itself: no blur, no thread.
    case watching = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// 0 at `none`, 0.5 at `glance`, 1 at `watching`: the one value the
    /// backdrop animates.
    var clearing: CGFloat { CGFloat(rawValue) / 2 }

    /// The blur's radius for a clearing between 0 and 1 (5, 1.5, 0).
    static func blurRadius(clearing: CGFloat) -> CGFloat {
        let c = min(max(clearing, 0), 1)
        return c < 0.5 ? 5 - 7 * c : 3 * (1 - c)
    }

    /// The tint's share of its resting opacity (the drawing's 0.24, 0.12, 0).
    static func tintShare(clearing: CGFloat) -> CGFloat { 1 - min(max(clearing, 0), 1) }

    /// The saturation boost (the drawing's 1.3, 1.15, none).
    static func saturation(clearing: CGFloat) -> CGFloat { 1.3 - 0.3 * min(max(clearing, 0), 1) }
}

/// A change the chat shows being made on its page while watching. The
/// change is saved before any of it shows.
enum AgentWatchedAction: Equatable, Sendable {
    /// The agent opens a page: the spark goes to the island and taps it.
    case openPage(AgentPage)
    /// A note edit, written in.
    case note(UUID)
    /// A new or changed calendar event: the day is picked, the card grows in.
    case calendarEvent(AgentTarget)
    /// Objects added to a Draw canvas, sketched in.
    case sketch(canvas: UUID, objects: [UUID])

    var page: AgentPage {
        switch self {
        case let .openPage(page): page
        case .note: .notes
        case .calendarEvent: .calendar
        case .sketch: .draw
        }
    }

    /// What a step does on its page, once it has done it.
    @MainActor static func finished(_ step: AgentStep) -> AgentWatchedAction? {
        switch step.state {
        case .done, .partial: break
        case .running, .failed: return nil
        }
        if let note = AgentChatModel.writtenNote(step) { return .note(note) }
        guard !step.targets.isEmpty else { return nil }
        switch step.kind {
        case .create, .update:
            if step.targets.allSatisfy({ $0.page == .calendar }), let event = step.targets.first(where: { $0.externalID != nil }) {
                return .calendarEvent(event)
            }
            if step.kind == .create, step.targets.allSatisfy({ $0.page == .draw && $0.containerID != nil && $0.itemID != nil }),
               let canvas = step.targets.first?.containerID, step.targets.allSatisfy({ $0.containerID == canvas }) {
                return .sketch(canvas: canvas, objects: step.targets.compactMap(\.itemID))
            }
            return nil
        default:
            return nil
        }
    }

    /// Whether a step just started is one the chat steps aside for: the
    /// agent is about to work on a page you can watch.
    static func watchable(_ step: AgentStep) -> Bool {
        guard !step.targets.isEmpty else { return false }
        switch step.kind {
        case .openPage:
            return true
        case .create:
            return step.targets.allSatisfy { $0.page == .calendar || $0.page == .draw }
                || (step.targets.count == 1 && step.targets[0].page == .notes && step.targets[0].itemID != nil)
        case .update:
            return step.targets.count == 1 && (step.targets[0].page == .notes || step.targets[0].page == .calendar)
        default:
            return false
        }
    }
}

/// A point the watching motion uses: in the window's coordinates (AppKit,
/// from an `NSView`), or SwiftUI's global space in the panel's one hosting view.
struct AgentWatchPoint: Equatable, Sendable {
    enum Space: Equatable, Sendable { case window, global }
    var point: CGPoint
    var space: Space

    static func window(_ point: CGPoint) -> AgentWatchPoint { AgentWatchPoint(point: point, space: .window) }
    static func global(_ point: CGPoint) -> AgentWatchPoint { AgentWatchPoint(point: point, space: .global) }
}

/// A rect, in the same two spaces.
struct AgentWatchRect: Equatable, Sendable {
    var rect: CGRect
    var space: AgentWatchPoint.Space

    var centre: AgentWatchPoint { AgentWatchPoint(point: CGPoint(x: rect.midX, y: rect.midY), space: space) }
}

/// A sketch being drawn in over Draw: each path, in window coordinates, and
/// how much of it is drawn. The replay is the design's `drawAct`; the objects
/// themselves are already saved and stay hidden under it until it ends.
@MainActor
final class AgentSketchReplay: Equatable {
    struct Stroke {
        var path: CGPath
        var colour: Color
        var width: CGFloat
        var drawn: CGFloat = 0
    }

    struct Label {
        var text: String
        var origin: CGPoint
        var size: CGFloat
        var colour: Color
        var shown: CGFloat = 0
    }

    var strokes: [Stroke] = []
    var labels: [Label] = []
    var finished = false

    nonisolated static func == (lhs: AgentSketchReplay, rhs: AgentSketchReplay) -> Bool { lhs === rhs }
}

/// Where the pages put what a watched action reaches for: a calendar day's
/// key, an event's row. Frames are SwiftUI's global space; reported, not
/// published, so nothing redraws for them. What is hidden until the agent
/// shows it, and what grows in, is published for the rows to read.
@MainActor
final class AgentWatchBoard: ObservableObject {
    static let shared = AgentWatchBoard()

    /// Global frames, by key: `day:<DueDay raw>`, `event:<occurrence id>`.
    private(set) var frames: [String: CGRect] = [:]
    /// Events saved but not yet shown: their rows take no room yet.
    @Published private(set) var hiddenEvents: Set<String> = []
    /// Events growing in now.
    @Published private(set) var growingEvents: Set<String> = []
    /// Calendar's selected day, as the agent picks it.
    @Published private(set) var dayRequest: (day: DueDay, id: UUID)?

    func report(_ key: String, frame: CGRect) { frames[key] = frame }
    func forget(_ key: String) { frames[key] = nil }
    func frame(_ key: String) -> CGRect? { frames[key] }

    func hideEvent(_ id: String) { hiddenEvents.insert(id) }
    func growEvent(_ id: String) {
        hiddenEvents.remove(id)
        growingEvents.insert(id)
    }
    /// However the action ends, nothing stays hidden.
    func settleEvent(_ id: String) {
        if hiddenEvents.contains(id) { hiddenEvents.remove(id) }
        if growingEvents.contains(id) { growingEvents.remove(id) }
    }

    func pick(_ day: DueDay) { dayRequest = (day, UUID()) }
    /// A page that took the day: a page drawn later never picks it again.
    func consumeDay(_ id: UUID) {
        guard dayRequest?.id == id else { return }
        DispatchQueue.main.async { [weak self] in if self?.dayRequest?.id == id { self?.dayRequest = nil } }
    }

    static func dayKey(_ day: DueDay) -> String { "day:\(day.rawValue)" }
    static func eventKey(_ id: String) -> String { "event:\(id)" }
}

extension View {
    /// Reports this view's global frame under `key` while it is on screen.
    func agentWatchMark(_ key: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            AgentWatchBoard.shared.report(key, frame: frame)
        }
        .onDisappear { AgentWatchBoard.shared.forget(key) }
    }
}

/// An event row the agent added: hidden until it is shown, then grown in
/// (the drawing's 480 ms, height from nothing, a 7 pt slide from the left).
struct AgentEventArrival: ViewModifier {
    let id: String
    @ObservedObject private var board = AgentWatchBoard.shared
    @Environment(\.atticDesign) private var design
    @State private var height: CGFloat = 0
    /// Only read while growing: from nothing, the first frame included.
    @State private var grown: CGFloat = 0

    init(id: String) { self.id = id }

    func body(content: Content) -> some View {
        let growing = board.growingEvents.contains(id)
        let p: CGFloat = board.hiddenEvents.contains(id) ? 0 : growing && !design.reduceMotion ? grown : 1
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { if $0 != height { height = $0 } }
            .agentWatchMark(AgentWatchBoard.eventKey(id))
            .offset(x: -7 * (1 - p))
            .opacity(Double(p))
            .frame(height: p < 1 ? height * p : nil, alignment: .top)
            // Clipped only while it grows: a grown row keeps its focus ring.
            .mask { Rectangle().padding(p < 1 ? 0 : -60) }
            .onChange(of: growing, initial: true) { _, now in
                guard now else { grown = 0; return }
                withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.48)) { grown = 1 }
            }
    }
}
