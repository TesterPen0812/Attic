import AppKit

struct AtticReorderGeometry: Equatable {
    nonisolated(unsafe) static var comparisonCount = 0
    private let indices: [UUID: Int]
    private let heights: [CGFloat]
    private let prefix: [CGFloat]
    init(group: [UUID], height: (UUID) -> CGFloat) {
        indices = Dictionary(uniqueKeysWithValues: group.enumerated().map { ($0.element, $0.offset) })
        heights = group.map(height)
        var sums: [CGFloat] = [0]
        for height in heights { sums.append(sums.last! + height) }
        prefix = sums
    }
    func index(_ id: UUID) -> Int? { indices[id] }
    func height(_ id: UUID) -> CGFloat? { indices[id].map { heights[$0] } }
    func landingDelta(start: Int, target: Int) -> CGFloat {
        target > start ? prefix[target + 1] - prefix[start + 1] : prefix[target] - prefix[start]
    }
    func target(start: Int, translation: CGFloat) -> Int {
        guard heights.indices.contains(start), translation != 0 else { return start }
        var low = translation > 0 ? start + 1 : 0
        var high = translation > 0 ? heights.count : start
        while low < high {
            Self.comparisonCount += 1
            let mid = (low + high) / 2
            if translation > 0 {
                let boundary = prefix[mid] - prefix[start + 1] + heights[mid] / 2
                if translation > boundary { low = mid + 1 } else { high = mid }
            } else {
                let boundary = prefix[start] - prefix[mid + 1] + heights[mid] / 2
                if -translation > boundary { high = mid } else { low = mid + 1 }
            }
        }
        return translation > 0 ? low - 1 : low
    }
    func pushesPastGroup(start: Int, translation: CGFloat) -> Bool {
        guard heights.indices.contains(start) else { return false }
        let room = translation > 0 ? prefix.last! - prefix[start + 1] : prefix[start]
        return abs(translation) > room + heights[start] / 2
    }
}

struct AtticReorderPosition: Equatable {
    let id: UUID
    let group: [UUID]
    let startIndex: Int
    var targetIndex: Int
    var geometry: AtticReorderGeometry? = nil
}

/// Reordering math shared by Task list rows and the subtask Quick Look.
enum AtticReorderSupport {
    /// How far a neighbour moves aside while `drag` is on its way: the
    /// dragged row's height, for the rows between where it was and where
    /// it would land.
    static func offset(of id: UUID, in drag: AtticReorderPosition, heights: (UUID) -> CGFloat) -> CGFloat {
        guard drag.id != id, let index = drag.geometry?.index(id) ?? drag.group.firstIndex(of: id) else { return 0 }
        let height = heights(drag.id)
        if drag.startIndex < drag.targetIndex, index > drag.startIndex, index <= drag.targetIndex { return -height }
        if drag.targetIndex < drag.startIndex, index >= drag.targetIndex, index < drag.startIndex { return height }
        return 0
    }

    /// The place the row would land: it passes a neighbour once it has
    /// moved more than half that neighbour's height.
    static func target(start: Int, translation: CGFloat, group: [UUID], heights: (UUID) -> CGFloat, geometry: AtticReorderGeometry? = nil) -> Int {
        if let geometry { return geometry.target(start: start, translation: translation) }
        var target = start
        var remaining = translation
        if remaining > 0 {
            for index in (start + 1)..<max(start + 1, group.count) {
                let height = heights(group[index])
                guard remaining > height / 2 else { break }
                target = index
                remaining -= height
            }
        } else if remaining < 0, start > 0 {
            for index in stride(from: start - 1, through: 0, by: -1) {
                let height = heights(group[index])
                guard -remaining > height / 2 else { break }
                target = index
                remaining += height
            }
        }
        return target
    }

    /// The row has been pushed more than half a row beyond its group's
    /// first or last place (where the other group begins).
    static func pushesPastGroup(start: Int, translation: CGFloat, group: [UUID], heights: (UUID) -> CGFloat, geometry: AtticReorderGeometry? = nil) -> Bool {
        if let geometry { return geometry.pushesPastGroup(start: start, translation: translation) }
        guard group.indices.contains(start) else { return false }
        let own = heights(group[start])
        if translation > 0 {
            let room = group[(start + 1)...].reduce(0) { $0 + heights($1) }
            return translation > room + own / 2
        }
        let room = group[..<start].reduce(0) { $0 + heights($1) }
        return -translation > room + own / 2
    }
}

/// SwiftUI tracks the mouse without necessarily dispatching queued keys.
/// A reorder drag owns Escape until release, even after it has sprung home.
/// Only one pointer drag can be active; the weak link lets the page's key
/// monitor give it precedence over every other Escape action.
@MainActor
final class AtticDragCancellation {
    private static weak var active: AtticDragCancellation?
    private weak var window: NSWindow?
    private var wasKey = false
    private var timer: Timer?
    private var keyLoss: NSObjectProtocol?
    private var onCancel: (() -> Void)?
    private(set) var isTracking = false
    private(set) var isCancelled = false

    func begin(in window: NSWindow?, onCancel: @escaping () -> Void) {
        guard !isTracking, let window else { return }
        self.window = window
        wasKey = window.isKeyWindow
        self.onCancel = onCancel
        isTracking = true
        isCancelled = false
        Self.active = self
        keyLoss = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                         object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Called before the page's editor, search, expansion or panel chain.
    static func consumeEscape(_ event: NSEvent) -> Bool {
        guard let active, active.isTracking, event.window === active.window,
              AtticDragTracking.isCancel(event) else { return false }
        active.cancel()
        return true
    }

    static func cancel(in window: NSWindow?) {
        guard let window, active?.window === window else { return }
        active?.cancel()
    }

    func poll() {
        guard isTracking else { return }
        // Dequeue only Escape for this window. Other keys keep their place.
        // This also catches a short press entirely between two timer ticks.
        while let event = NSApp.nextEvent(matching: .keyDown, until: Date(), inMode: .eventTracking, dequeue: false),
              event.window === window, AtticDragTracking.isCancel(event) {
            _ = NSApp.nextEvent(matching: .keyDown, until: Date(), inMode: .eventTracking, dequeue: true)
            cancel()
        }
        if window == nil || window?.isVisible != true || (wasKey && window?.isKeyWindow != true) { cancel() }
    }

    func cancel() {
        guard isTracking, !isCancelled else { return }
        isCancelled = true
        let action = onCancel
        onCancel = nil
        action?()
    }

    func end() {
        poll()
        timer?.invalidate()
        timer = nil
        if let keyLoss { NotificationCenter.default.removeObserver(keyLoss) }
        keyLoss = nil
        onCancel = nil
        window = nil
        isTracking = false
        if Self.active === self { Self.active = nil }
    }

    deinit {
        timer?.invalidate()
        if let keyLoss { NotificationCenter.default.removeObserver(keyLoss) }
    }
}
