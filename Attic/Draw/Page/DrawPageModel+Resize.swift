import AppKit

/// A selection handle (Planning.md, Draw › Selection: the outline's handles).
enum DrawHandle: Hashable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
    /// A text box's sides.
    case left, right
    /// A line's or arrow's ends.
    case start, end

    var isCorner: Bool { [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(self) }
}

/// A handle where the board draws it, in board points (y down).
struct DrawHandleSpot: Equatable {
    var handle: DrawHandle
    var point: CGPoint
}

/// A handle drag under way: the objects as they were when it began and as
/// they are drawn now. Nothing reaches the store until the drag ends.
struct DrawResize: Equatable {
    var handle: DrawHandle
    var from: CGPoint
    var originals: [DrawObject]
    var current: [DrawObject]
    var delta: CGPoint = .zero
    var constrained = false
}

extension DrawPageModel {
    /// The 6 pt handle takes presses this far from its centre.
    static let handleHitRadius: CGFloat = 8
    /// The outline sits this far outside what it wraps (screen points).
    static let outlineGap: CGFloat = 4
    /// Nothing resizes below this (world points).
    static let minimumResize: CGFloat = 4

    /// The selection as drawn right now (a handle drag's live geometry).
    var displayedSelection: [DrawObject] {
        if case .resize(let resize) = live { return resize.current }
        return selectedObjects
    }

    /// What the next raster draws in place of the stored objects.
    var rasterReplacements: [UUID: DrawObject] {
        guard case .resize(let resize) = live else { return [:] }
        return Dictionary(uniqueKeysWithValues: resize.current.map { ($0.id, $0) })
    }

    /// The handles of the selection, as drawn: a line's two ends, a text
    /// box's sides, one object's corners, or the corners around several.
    var handleSpots: [DrawHandleSpot] {
        let chosen = displayedSelection
        guard !chosen.isEmpty, editing == nil else { return [] }
        let offset = rasterMove?.offset ?? .zero
        if chosen.count == 1, case .shape(let kind) = chosen[0].content, kind == .line || kind == .arrow {
            let (a, b) = DrawGeometry.endpoints(chosen[0].frame)
            return [DrawHandleSpot(handle: .start, point: viewport.screen(CGPoint(x: a.x + offset.x, y: a.y + offset.y))),
                    DrawHandleSpot(handle: .end, point: viewport.screen(CGPoint(x: b.x + offset.x, y: b.y + offset.y)))]
        }
        // Moving a selection changes only its position; translating stroke
        // point arrays here would allocate every sample on every mouse event.
        guard let union = DrawGeometry.union(chosen)?.offsetBy(dx: offset.x, dy: offset.y) else { return [] }
        let rect = viewport.screen(union).insetBy(dx: -Self.outlineGap, dy: -Self.outlineGap)
        if chosen.count == 1, case .text = chosen[0].content {
            return [DrawHandleSpot(handle: .left, point: CGPoint(x: rect.minX, y: rect.midY)),
                    DrawHandleSpot(handle: .right, point: CGPoint(x: rect.maxX, y: rect.midY))]
        }
        return [DrawHandleSpot(handle: .topLeft, point: CGPoint(x: rect.minX, y: rect.minY)),
                DrawHandleSpot(handle: .topRight, point: CGPoint(x: rect.maxX, y: rect.minY)),
                DrawHandleSpot(handle: .bottomLeft, point: CGPoint(x: rect.minX, y: rect.maxY)),
                DrawHandleSpot(handle: .bottomRight, point: CGPoint(x: rect.maxX, y: rect.maxY))]
    }

    /// The handle under a press, if any (the nearest within the hit radius).
    func handleSpot(at screen: CGPoint) -> DrawHandleSpot? {
        guard tool == .select else { return nil }
        let r = Self.handleHitRadius
        return handleSpots
            .filter { abs($0.point.x - screen.x) <= r && abs($0.point.y - screen.y) <= r }
            .min { hypot($0.point.x - screen.x, $0.point.y - screen.y) < hypot($1.point.x - screen.x, $1.point.y - screen.y) }
    }

    /// The objects after dragging `handle` by `delta` (world points).
    ///
    /// `minimum` is the pointer's smallest extent. An explicit scale factor
    /// (VoiceOver, the keyboard) passes 0 so that a smaller command can never
    /// force a short object up to that minimum and make it bigger.
    static func resized(_ originals: [DrawObject], handle: DrawHandle, delta: CGPoint, shift: Bool,
                        minimum: CGFloat = DrawPageModel.minimumResize) -> [DrawObject] {
        guard let first = originals.first else { return [] }
        if originals.count == 1 {
            switch handle {
            case .start, .end:
                var object = first
                let (a, b) = DrawGeometry.endpoints(first.frame)
                let moved = handle == .start ? CGPoint(x: a.x + delta.x, y: a.y + delta.y) : CGPoint(x: b.x + delta.x, y: b.y + delta.y)
                object.frame = handle == .start ? DrawGeometry.lineFrame(from: moved, to: b) : DrawGeometry.lineFrame(from: a, to: moved)
                return [object]
            case .left, .right:
                var object = first
                let width = max(minimum, first.frame.width + (handle == .right ? delta.x : -delta.x))
                if handle == .left { object.frame.x = first.frame.x + first.frame.width - width }
                object.textWidth = width
                measure(&object, text: object.text)
                return [object]
            default:
                break
            }
        }
        // Corners: the opposite corner of the frames stays put.
        let box = originals.dropFirst().reduce(DrawGeometry.frame(first.frame)) { $0.union(DrawGeometry.frame($1.frame)) }
        let anchor = CGPoint(x: handle == .topLeft || handle == .bottomLeft ? box.maxX : box.minX,
                             y: handle == .topLeft || handle == .topRight ? box.maxY : box.minY)
        let signX: CGFloat = handle == .topLeft || handle == .bottomLeft ? -1 : 1
        let signY: CGFloat = handle == .topLeft || handle == .topRight ? -1 : 1
        let flatX = box.width < 0.001, flatY = box.height < 0.001
        var sx = flatX ? 1 : max(minimum, box.width + signX * delta.x) / box.width
        var sy = flatY ? 1 : max(minimum, box.height + signY * delta.y) / box.height
        // Images and groups keep their proportions; Shift keeps a shape's.
        let uniform = shift || originals.count > 1 || first.isImage || flatX || flatY
        if uniform {
            // A zero extent is a straight line or point, not a tiny length
            // from which to derive a huge reciprocal scale. An axis shorter
            // than the pointer minimum must not let that minimum decide (a
            // 2 pt axis "doubles" to 4 pt), so such a box is scaled from the
            // pointer's travel instead, and never made larger by an inward drag.
            let dx = signX * delta.x, dy = signY * delta.y
            let shortX = box.width < minimum, shortY = box.height < minimum
            var s: CGFloat
            if !(shortX || shortY) {
                s = flatX ? sy : flatY ? sx : abs(sx - 1) >= abs(sy - 1) ? sx : sy
            } else {
                let longest = max(box.width, box.height)
                if longest < 0.001 {
                    s = 1 // a point
                } else if flatX || flatY {
                    s = 1 + (flatX ? dy : dx) / longest
                } else if shortX && shortY {
                    let rx = (box.width + dx) / box.width, ry = (box.height + dy) / box.height
                    s = abs(rx - 1) >= abs(ry - 1) ? rx : ry
                } else {
                    // One short axis: the larger pointer travel counts, against
                    // the long axis (a tie goes to the long axis).
                    let longIsX = !shortX
                    let along = longIsX ? dx : dy, across = longIsX ? dy : dx
                    s = 1 + (abs(across) > abs(along) ? across : along) / longest
                }
                // Not below the minimum on the long axis, but an object that
                // is already short never grows from being dragged smaller.
                s = max(s, min(1, minimum / longest))
            }
            sx = s
            sy = s
        }
        func map(_ x: Double, _ y: Double) -> DrawPoint {
            DrawPoint(x: anchor.x + (x - anchor.x) * sx, y: anchor.y + (y - anchor.y) * sy)
        }
        return originals.map { original in
            var object = original
            let rect = DrawGeometry.frame(original.frame)
            switch original.content {
            case .text:
                // A text box in a group scales with it, like a stroke: its
                // size and wrap width together, so its lines scale rather
                // than reflow. Groups always keep their proportions; should
                // the two ever differ, text takes the smaller.
                let scale = min(sx, sy)
                let corner = map(rect.minX, rect.minY)
                object.frame.x = corner.x
                object.frame.y = corner.y
                let total = (original.textScale ?? 1) * scale
                object.textScale = abs(total - 1) < 0.000_001 ? nil : total
                object.textWidth = original.textWidth.map { $0 * scale }
                measure(&object, text: object.text)
            case .shape(let kind) where kind == .line || kind == .arrow:
                let (a, b) = DrawGeometry.endpoints(original.frame)
                let p = map(a.x, a.y), q = map(b.x, b.y)
                object.frame = DrawFrame(x: p.x, y: p.y, width: q.x - p.x, height: q.y - p.y)
            case .stroke(let points):
                let mapped = points.map { point in
                    var transformed = map(point.x, point.y)
                    transformed.pressure = point.pressure
                    return transformed
                }
                object.content = .stroke(mapped)
                object.frame = DrawGeometry.strokeFrame(mapped)
            default:
                let p = map(rect.minX, rect.minY), q = map(rect.maxX, rect.maxY)
                object.frame = DrawFrame(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(q.x - p.x), height: abs(q.y - p.y))
            }
            return object
        }
    }

    /// A press on a handle starts a resize (the select tool only).
    func beginResize(_ spot: DrawHandleSpot, at world: CGPoint) {
        let chosen = selectedObjects
        guard !chosen.isEmpty else { return }
        live = .resize(DrawResize(handle: spot.handle, from: world, originals: chosen, current: chosen))
        isMovingSelection = true
        board?.drawLiveChanged()
    }

    func dragResize(_ resize: DrawResize, to world: CGPoint, shift: Bool) {
        var next = resize
        next.delta = CGPoint(x: world.x - resize.from.x, y: world.y - resize.from.y)
        next.constrained = shift
        next.current = Self.resized(resize.originals, handle: resize.handle, delta: next.delta, shift: shift)
        guard next != resize else { return }
        live = .resize(next)
        board?.drawLiveChanged()
        board?.drawContentChanged()
    }

    /// The drag's end: one store command, one Undo step, one save.
    func finishResize(_ resize: DrawResize) {
        isMovingSelection = false
        let fresh = resize.originals.compactMap { original in object(original.id) }
        guard fresh.count == resize.originals.count else { board?.drawContentChanged(); return }
        let current = fresh == resize.originals ? resize.current
            : Self.resized(fresh, handle: resize.handle, delta: resize.delta, shift: resize.constrained)
        if current != fresh { performAcknowledged(.put(current)) } else { board?.drawContentChanged() }
    }

    /// VoiceOver's and the keyboard's way to resize the selection: a tenth
    /// larger or smaller from its top-left corner, one Undo step.
    func scaleSelection(by factor: CGFloat) {
        syncExternalChanges()
        let chosen = selectedObjects
        guard let first = chosen.first, DrawGeometry.union(chosen) != nil, live == nil else { return }
        // Match resized(_:)'s raw object frames. The painted union includes
        // half the stroke width, which distorts a requested 0.9× or 1.1×.
        let box = chosen.dropFirst().reduce(DrawGeometry.frame(first.frame)) {
            $0.union(DrawGeometry.frame($1.frame))
        }
        let delta = CGPoint(x: box.width * (factor - 1), y: box.height * (factor - 1))
        let handle: DrawHandle = chosen.count == 1 && chosen[0].text.isEmpty == false ? .right : .bottomRight
        performAcknowledged(.put(Self.resized(chosen, handle: handle, delta: delta, shift: true, minimum: 0)))
    }
}
