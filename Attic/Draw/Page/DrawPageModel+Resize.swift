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
        let isLiveResize: Bool
        if case .resize = live { isLiveResize = true } else { isLiveResize = false }
        guard let first = chosen.first else { return [] }
        var union = inputBounds(for: first, transient: isLiveResize)
        for object in chosen.dropFirst() {
            union = union.union(inputBounds(for: object, transient: isLiveResize))
        }
        union = union.offsetBy(dx: offset.x, dy: offset.y)
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
    static func resized(_ originals: [DrawObject], handle: DrawHandle, delta: CGPoint, shift: Bool) -> [DrawObject] {
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
                let width = max(Self.minimumResize, first.frame.width + (handle == .right ? delta.x : -delta.x))
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
        let width = max(box.width, 0.0001), height = max(box.height, 0.0001)
        var sx = max(Self.minimumResize, box.width + signX * delta.x) / width
        var sy = max(Self.minimumResize, box.height + signY * delta.y) / height
        // Images and groups keep their proportions; Shift keeps a shape's.
        let uniform = shift || originals.count > 1 || first.isImage || box.width < 0.001 || box.height < 0.001
        if uniform {
            let s = abs(sx - 1) >= abs(sy - 1) ? sx : sy
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
        guard let union = DrawGeometry.union(chosen), live == nil else { return }
        let delta = CGPoint(x: union.width * (factor - 1), y: union.height * (factor - 1))
        let handle: DrawHandle = chosen.count == 1 && chosen[0].text.isEmpty == false ? .right : .bottomRight
        performAcknowledged(.put(Self.resized(chosen, handle: handle, delta: delta, shift: true)))
    }
}
