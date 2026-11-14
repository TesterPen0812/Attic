import AppKit

/// A key on the board, as the board view reads it from an event.
struct DrawKey: Equatable {
    /// The key's characters ignoring modifiers, lowercased.
    var characters: String
    var keyCode: UInt16 = 0
    var command = false
    var shift = false
    var option = false
    var control = false

    static let escapeCode: UInt16 = 53
    static let deleteCode: UInt16 = 51
    static let forwardDeleteCode: UInt16 = 117
    static let returnCode: UInt16 = 36
    static let enterCode: UInt16 = 76
    static let oneCode: UInt16 = 18
    static let zeroCode: UInt16 = 29
}

/// The board's pointer, gesture and key handling. Input handlers only change
/// state and tell the board view what moved; they never raster, wait or
/// rebuild the board (restart plan §2).
extension DrawPageModel {
    /// B4: top-to-bottom rows whose centres are within 30 pt (60 design
    /// px), left-to-right inside each row. Layer order does not change it.
    var objectNavigationIDs: [UUID] {
        if let cached = objectNavigationCache, cached.revision == contentRevision { return cached.ids }
        let positioned = objects.filter { $0.deletedAt == nil }.map { (id: $0.id, rect: DrawGeometry.bounds($0)) }.sorted {
            if $0.rect.midY != $1.rect.midY { return $0.rect.midY < $1.rect.midY }
            return $0.id.uuidString < $1.id.uuidString
        }
        var rows: [[(id: UUID, rect: CGRect)]] = []
        var rowMiddle: CGFloat = 0
        for item in positioned {
            if !rows.isEmpty, abs(item.rect.midY - rowMiddle) < 30 { rows[rows.count - 1].append(item) }
            else { rows.append([item]); rowMiddle = item.rect.midY }
        }
        let ids = rows.flatMap { row in row.sorted {
            if $0.rect.minX != $1.rect.minX { return $0.rect.minX < $1.rect.minX }
            if $0.rect.midY != $1.rect.midY { return $0.rect.midY < $1.rect.midY }
            return $0.id.uuidString < $1.id.uuidString
        }.map(\.id) }
        objectNavigationCache = (contentRevision, ids)
        return ids
    }

    private func moveObjectFocus(by delta: Int, leavesBoard: Bool) -> Bool {
        guard editing == nil, live == nil, let canvasID else { return false }
        let ids = objectNavigationIDs
        guard !ids.isEmpty else { return false }
        let current = selection.count == 1 ? ids.firstIndex(of: selection[0]) : nil
        let next = current.map { $0 + delta } ?? (delta > 0 ? 0 : ids.count - 1)
        guard ids.indices.contains(next) else {
            if leavesBoard { select([]); return false }
            return true
        }
        reveal(canvasID: canvasID, objectID: ids[next])
        return true
    }

    /// The working file's 8 px pick tolerance.
    var pickTolerance: CGFloat { 4 / viewport.zoom }

    // MARK: Pointer

    func pointerDown(at screen: CGPoint, shift: Bool = false, panButton: Bool = false, pressure: CGFloat? = nil) {
        guard canvasID != nil else { return }
        if let live {
            if case .pan = live { return }
            // A second button must settle the first gesture's work before
            // taking over. Its later button-up must not discard that work.
            guard panButton else { return }
            finishLiveInput()
        }
        syncExternalChanges()
        lastPointerShift = shift
        if isFiltering { closeFilter(); return }
        if editing != nil { endEditing(); return }
        if isSelectionStyleOpen { isSelectionStyleOpen = false; return }
        if let open = strip {
            strip = nil
            // Pressing on the board while the shapes are open draws the
            // current shape straight away; the other strips just close.
            if open != .shape { return }
        }
        let world = viewport.world(screen)
        if panButton || spaceHeld {
            liveStartedWithMiddleButton = panButton
            begin(.pan(start: screen, viewport: viewport))
            return
        }
        switch tool {
        case .pen:
            select([])
            begin(.ink(DrawInkTrace(DrawInkSample(point: world, pressure: pressure))))
        case .eraser:
            begin(.erase(gone: [], last: world))
            erase(to: world)
        case .text:
            if let hit = DrawGeometry.pick(objects, at: world, tolerance: pickTolerance), case .text = hit.content {
                edit(hit.id)
            } else {
                beginText(at: world)
            }
        case .shape:
            select([])
            begin(.shape(shape, start: world, end: world))
        case .select:
            if let spot = handleSpot(at: screen) {
                beginResize(spot, at: world)
            } else if let hit = DrawGeometry.pick(objects, at: world, tolerance: pickTolerance) {
                if shift {
                    select(selection.contains(hit.id) ? selection.filter { $0 != hit.id } : selection + [hit.id])
                } else if !selection.contains(hit.id) {
                    select([hit.id])
                }
                begin(.move(from: world, offset: .zero, moved: false))
            } else {
                let base = shift ? Set(selection) : []
                if !shift { select([]) }
                begin(.marquee(from: world, to: world, base: base))
            }
        }
    }

    func pointerDragged(to screen: CGPoint, shift: Bool = false, pressure: CGFloat? = nil, panButton: Bool? = nil) {
        guard let live else { return }
        if let panButton, panButton != liveStartedWithMiddleButton { return }
        lastPointerShift = shift
        let world = viewport.world(screen)
        switch live {
        case .pan(let start, let from):
            setViewport(from.panned(dx: screen.x - start.x, dy: screen.y - start.y), byUser: true)
            return
        case .ink(let trace):
            // The live trace is reference-owned by this gesture. Avoid
            // appending to a copied array on every event as it grows.
            trace.append(DrawInkSample(point: world, pressure: pressure))
            board?.drawLiveChanged()
        case .erase:
            erase(to: world)
        case .shape(let kind, let start, _):
            var end = world
            if shift {
                let dx = world.x - start.x, dy = world.y - start.y
                if kind == .line || kind == .arrow {
                    let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4), radius = hypot(dx, dy)
                    end = CGPoint(x: start.x + cos(angle) * radius, y: start.y + sin(angle) * radius)
                } else {
                    let side = max(abs(dx), abs(dy))
                    end = CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
                }
            }
            setLive(.shape(kind, start: start, end: end))
        case .move(let from, _, let moved):
            let offset = CGPoint(x: world.x - from.x, y: world.y - from.y)
            let nowMoved = moved || hypot(offset.x, offset.y) * viewport.zoom > 3
            if nowMoved, !isMovingSelection { setMoving(true) }
            setLive(.move(from: from, offset: offset, moved: nowMoved))
            if nowMoved { board?.drawContentChanged() }
        case .marquee(let from, _, let base):
            setLive(.marquee(from: from, to: world, base: base))
        case .resize(let resize):
            dragResize(resize, to: world, shift: shift)
        }
    }

    func pointerUp(at screen: CGPoint? = nil, shift: Bool? = nil, pressure: CGFloat? = nil, panButton: Bool? = nil) {
        guard live != nil, panButton == nil || panButton == liveStartedWithMiddleButton else { return }
        if let screen { pointerDragged(to: screen, shift: shift ?? lastPointerShift, pressure: pressure) }
        finishLiveInput()
    }

    func doubleClick(at screen: CGPoint) {
        guard tool == .select, editing == nil else { return }
        let world = viewport.world(screen)
        if let hit = DrawGeometry.pick(objects, at: world, tolerance: pickTolerance) {
            if case .text = hit.content { edit(hit.id) }
        } else {
            beginText(at: world)
        }
    }

    /// Ends whatever the pointer is doing, as drawn: mouse-up, and also a
    /// hide, a page switch or a canvas change (a stroke is never cancelled).
    func finishLiveInput() {
        guard let finished = live else { return }
        let startedOnCanvas = canvasID
        live = nil
        liveStartedWithMiddleButton = false
        // A gesture must finish against current objects. Otherwise a move
        // can put back a remotely deleted box or undo an agent restyle.
        syncExternalChanges()
        // An agent can delete the active canvas mid-gesture. Reconciliation
        // then opens another canvas, which must never receive this gesture.
        guard canvasID == startedOnCanvas else {
            isDrawingLive = false
            isMovingSelection = false
            board?.drawLiveChanged()
            return
        }
        switch finished {
        case .pan:
            break
        case .ink(let trace):
            let samples = DrawInk.smooth(trace.samples)
            if !samples.isEmpty {
                let object = DrawObject(frame: DrawGeometry.strokeFrame(samples), zIndex: topZ + 1,
                                        style: DrawStyle(colour: colour, size: strokeSize, corners: .square),
                                        content: .stroke(samples))
                performAcknowledged(.put([object]))
            }
        case .erase(let gone, _):
            if !gone.isEmpty { performAcknowledged(.remove(Array(gone))) } else { board?.drawContentChanged() }
        case .shape(let kind, let start, let end):
            if hypot(end.x - start.x, end.y - start.y) * viewport.zoom >= 4 {
                let frame = kind == .line || kind == .arrow
                    ? DrawGeometry.lineFrame(from: start, to: end) : DrawGeometry.boxFrame(from: start, to: end)
                // Rectangles start square; Rounded is in Style.
                let object = DrawObject(frame: frame, zIndex: topZ + 1,
                                        style: DrawStyle(colour: colour, size: strokeSize, corners: .square),
                                        content: .shape(kind))
                performAcknowledged(.put([object]))
                // Shapes return to Select (and nothing is selected after adding).
                tool = .select
            }
        case .move(_, let offset, let moved):
            setMoving(false)
            if moved {
                let shift = DrawPoint(x: offset.x, y: offset.y)
                performAcknowledged(.put(selectedObjects.map { $0.translated(by: shift, id: $0.id) }))
            }
        case .marquee(let from, let to, let base):
            let rect = CGRect(x: from.x, y: from.y, width: to.x - from.x, height: to.y - from.y).standardized
            if max(rect.width, rect.height) * viewport.zoom > 4 {
                let inside = objects.filter { DrawGeometry.bounds($0).intersects(rect) }.map(\.id)
                select(Array(base) + inside.filter { !base.contains($0) })
            }
        case .resize(let resize):
            finishResize(resize)
        }
        if isDrawingLive { isDrawingLive = false }
        board?.drawLiveChanged()
        syncExternalChanges()
    }

    private func begin(_ next: DrawLive) {
        live = next
        switch next {
        case .ink, .shape, .erase: if !isDrawingLive { isDrawingLive = true }
        default: break
        }
        board?.drawLiveChanged()
    }

    private func setLive(_ next: DrawLive) {
        live = next
        board?.drawLiveChanged()
    }

    private func setMoving(_ moving: Bool) {
        isMovingSelection = moving
    }

    /// The eraser removes whole strokes along the path it crosses.
    private func erase(to world: CGPoint) {
        guard case .erase(var gone, let last) = live else { return }
        let tolerance = 5 / viewport.zoom
        let before = gone.count
        // Traverse the eraser's whole segment, even if AppKit coalesces a
        // long fast movement into two distant events. No per-4pt stepping.
        // Imported strokes can have stale frames, so use their real samples.
        let travel = CGRect(x: min(last.x, world.x), y: min(last.y, world.y),
                            width: abs(world.x - last.x), height: abs(world.y - last.y))
            .insetBy(dx: -1, dy: -1) // Horizontal and vertical travel must still have an area.
        for object in objects {
            guard !gone.contains(object.id), case .stroke(let samples) = object.content, !samples.isEmpty else { continue }
            guard let extent = strokeExtent(for: object) else { continue }
            let bounds = extent.bounds.insetBy(dx: -tolerance, dy: -tolerance)
            if bounds.intersects(travel) || bounds.contains(last) || bounds.contains(world) {
                if DrawGeometry.eraserTouches(samples, size: object.style.size,
                                              from: last, to: world, tolerance: tolerance) {
                    gone.insert(object.id)
                }
            }
        }
        live = .erase(gone: gone, last: world)
        if gone.count != before { board?.drawContentChanged() }
    }

    // MARK: Gestures

    /// Two-finger scroll pans; ⌘-scroll zooms (the working file's rate).
    func scroll(dx: CGFloat, dy: CGFloat, command: Bool, at screen: CGPoint) {
        if command {
            let factor = exp(max(-25, min(25, dy)) * 0.01)
            setViewport(viewport.zoomed(to: viewport.zoom * factor, around: screen), byUser: true)
            flashZoom()
        } else {
            setViewport(viewport.panned(dx: dx, dy: dy), byUser: true)
        }
    }

    func magnify(by amount: CGFloat, at screen: CGPoint) {
        setViewport(viewport.zoomed(to: viewport.zoom * (1 + amount), around: screen), byUser: true)
        flashZoom()
    }

    // MARK: Keys

    /// Escape: the innermost open thing closes, then the selection clears.
    @discardableResult
    func escape() -> Bool {
        if isSearching { closeSearch(); return true }
        if editing != nil { endEditing(); return true }
        if isFiltering { closeFilter(); return true }
        if isSelectionStyleOpen { isSelectionStyleOpen = false; return true }
        if strip != nil { strip = nil; return true }
        if !selection.isEmpty { select([]); return true }
        return false
    }

    /// The board's keys (Planning.md, Draw › Keys). Returns whether it was used.
    @discardableResult
    func handleKey(_ key: DrawKey) -> Bool {
        let k = key.characters
        if key.command, !key.option, !key.control {
            switch (k, key.shift) {
            case ("z", false): if !library.undoDeletionIfOffered() { undoAcknowledged() }
            case ("z", true): redoAcknowledged()
            case ("a", false): selectAll()
            case ("d", false): duplicateSelection()
            case ("c", false): copySelection()
            case ("x", false): cutSelection()
            case ("v", false): paste()
            default: return false
            }
            return true
        }
        guard !key.command, !key.control, !key.option else { return false }
        if key.keyCode == 48 { return moveObjectFocus(by: key.shift ? -1 : 1, leavesBoard: true) }
        if !key.shift {
            if key.keyCode == 123 || key.keyCode == 126 { return moveObjectFocus(by: -1, leavesBoard: false) }
            if key.keyCode == 124 || key.keyCode == 125 { return moveObjectFocus(by: 1, leavesBoard: false) }
        }
        if key.keyCode == DrawKey.escapeCode { return escape() }
        if key.keyCode == DrawKey.deleteCode || key.keyCode == DrawKey.forwardDeleteCode {
            guard !selection.isEmpty else { return false }
            deleteSelection()
            return true
        }
        if key.keyCode == DrawKey.returnCode || key.keyCode == DrawKey.enterCode {
            guard selection.count == 1, let object = object(selection[0]), case .text = object.content else { return false }
            edit(object.id)
            return true
        }
        if key.shift {
            if key.keyCode == DrawKey.oneCode { fit(); return true }
            if key.keyCode == DrawKey.zeroCode { actualSize(); return true }
            return false
        }
        switch k {
        case "v": setTool(.select)
        case "p": setTool(.pen)
        case "e": setTool(.eraser)
        case "t": setTool(.text)
        case "r": pickShape(.rectangle)
        case "o": pickShape(.ellipse)
        case "l": pickShape(.line)
        case "a": pickShape(.arrow)
        default: return false
        }
        return true
    }
}
