import CoreGraphics
import Observation
import SwiftUI
import UIKit

/// The phone's Draw page uses the same durable commands, geometry and raster
/// renderer as the Mac. All input state stays local to this view.
@MainActor
struct PhoneDrawEditor: View {
    @ObservedObject private var state: PhoneAppState
    private let canvasID: UUID

    @Environment(\.colorScheme) private var colourScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var textFocused: Bool

    @State private var activeID: UUID
    @State private var canvas: DrawCanvas?
    @State private var objects: [DrawObject] = []
    @State private var revision = 0
    @State private var viewport = DrawViewport()
    @State private var boardSize = CGSize.zero
    @State private var needsInitialFit = true
    @State private var userMovedBoard = false
    @State private var raster = PhoneDrawRasterState()

    @State private var tool: PhoneDrawTool = .pen
    @State private var strip: PhoneDrawStrip?
    @State private var shape: DrawShape = .rectangle
    @State private var colour: DrawColour = .ink
    @State private var strokeSize: DrawSize = .medium
    @State private var textSize: DrawSize = .medium
    @State private var selection: Set<UUID> = []
    @State private var addToSelection = false
    @State private var selectionStyleOpen = false
    @State private var input: PhoneDrawInput?
    @State private var textEdit: PhoneDrawTextEdit?

    @State private var showCanvasPicker = false
    @State private var canvasFilter = ""
    @State private var showRename = false
    @State private var renameDraft = ""
    @State private var showTags = false
    @State private var tagsDraft = ""
    @State private var confirmDelete = false
    @State private var share: PhoneDrawShare?
    @State private var exporting = false
    @State private var issue: String?
    @State private var zoomFlashing = false
    @State private var zoomFlashTask: Task<Void, Never>?
    @State private var thumbnailTask: Task<Void, Never>?

    init(state: PhoneAppState, canvasID: UUID) {
        self.state = state
        self.canvasID = canvasID
        _activeID = State(initialValue: canvasID)
    }

    private var dark: Bool { colourScheme == .dark }
    private var palette: DrawPalette { DrawPalette(dark: dark) }
    private var boardColour: Color {
        dark ? Color(red: 14 / 255, green: 14 / 255, blue: 15 / 255)
             : Color(red: 250 / 255, green: 250 / 255, blue: 250 / 255)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                board(in: geometry.size)
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 26)
                if let issue {
                    saveNotice(issue)
                        .padding(.horizontal, 16)
                        .padding(.top, 104)
                }
                if shouldShowZoom {
                    zoomPill
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 94)
                }
                toolbar
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(boardColour)
            .onAppear {
                boardSize = geometry.size
                openCanvas(activeID, fitting: true)
            }
            .onChange(of: geometry.size) { _, size in
                boardSize = size
                if needsInitialFit { fitCurrentCanvas() }
            }
        }
        .onChange(of: canvasID) { _, id in openCanvas(id, fitting: true) }
        .onChange(of: state.draw.revision) { _, _ in refreshSnapshot() }
        .onDisappear {
            finishInput()
            finishTextEditing()
            queueThumbnail(immediately: true)
            zoomFlashTask?.cancel()
            raster.cancel()
        }
        .sheet(item: $textEdit, onDismiss: finishTextEditing) { _ in textEditor }
        .sheet(isPresented: $showCanvasPicker) { canvasPicker }
        .sheet(item: $share) { file in PhoneDrawShareSheet(url: file.url) }
        .alert("Rename canvas", isPresented: $showRename) {
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") { command(.rename(renameDraft)) }
        } message: {
            Text("The name changes on this canvas.")
        }
        .alert("Canvas tags", isPresented: $showTags) {
            TextField("Tags, separated by commas", text: $tagsDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let tags = tagsDraft.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
                command(.tags(tags))
            }
        } message: {
            Text("Separate tags with commas.")
        }
        .confirmationDialog("Delete this canvas?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete canvas", role: .destructive) { deleteCanvas() }
        } message: {
            Text("The canvas can be restored from Recently Deleted.")
        }
    }

    // MARK: Board and renderer

    private func board(in size: CGSize) -> some View {
        let key = rasterKey(for: size)
        return ZStack(alignment: .topLeading) {
            boardColour
            Canvas(opaque: false, rendersAsynchronously: true) { context, _ in
                drawDots(context: context, size: size)
            }
            .allowsHitTesting(false)

            // An older bitmap may be reprojected during a pan or pinch, but
            // must never show content from a previous canvas or edit.
            if let picture = raster.image, let renderedKey = raster.key,
               renderedKey.revision == revision, renderedKey.dark == dark {
                let ratio = viewport.zoom / renderedKey.viewport.zoom
                Image(decorative: picture, scale: renderedKey.scale, orientation: .up)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: renderedKey.size.width, height: renderedKey.size.height)
                    .scaleEffect(ratio, anchor: .topLeading)
                    .offset(
                        x: viewport.x - renderedKey.viewport.x * ratio,
                        y: viewport.y - renderedKey.viewport.y * ratio
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            Canvas(opaque: false) { context, _ in drawLive(context: context) }
                .allowsHitTesting(false)

            PhoneDrawTouchSurface(
                began: { beginInput(at: $0) },
                moved: { positions in positions.forEach { moveInput(to: $0) } },
                ended: { position, taps in
                    moveInput(to: position)
                    finishInput()
                    if taps >= 2 { doubleTap(at: position) }
                },
                cancelled: { cancelInput() },
                panned: { delta in
                    viewport = viewport.panned(dx: delta.x, dy: delta.y)
                    userMovedBoard = true
                },
                pinched: { factor, anchor in
                    viewport = viewport.zoomed(to: viewport.zoom * factor, around: anchor)
                    userMovedBoard = true
                    flashZoom()
                }
            )
            .accessibilityLabel("Drawing board")
            .accessibilityHint("Draw with a finger or Apple Pencil. Use two fingers to pan or pinch to zoom.")

            selectionOverlay(in: size)
                .allowsHitTesting(false)
            selectionActionBar(in: size)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task(id: key) {
            let replacements: [UUID: DrawObject]
            if case .resize(let resize) = input {
                replacements = Dictionary(uniqueKeysWithValues: resize.current.map { ($0.id, $0) })
            } else {
                replacements = [:]
            }
            raster.request(DrawRasterRequest(key: key, objects: objects, replacements: replacements))
        }
    }

    private func rasterKey(for size: CGSize) -> DrawRasterKey {
        var key = DrawRasterKey()
        key.revision = revision
        key.viewport = viewport
        key.size = size
        key.scale = 2
        key.dark = dark
        switch input {
        case .erase(let removed, _):
            key.hidden = removed
        case .move(_, let offset):
            key.moved = selection
            key.offset = offset
        case .resize(let resize):
            key.replaced = Dictionary(uniqueKeysWithValues: resize.current.map { ($0.id, $0.frame) })
        default:
            break
        }
        return key
    }

    private func drawDots(context: GraphicsContext, size: CGSize) {
        // The 16pt world grid thins at low zoom, as on the Mac.
        var every = 1
        while 16 * viewport.zoom * CGFloat(every) < 8 { every *= 2 }
        let step = 16 * viewport.zoom * CGFloat(every)
        guard step.isFinite, step > 0 else { return }
        let firstX = viewport.x.truncatingRemainder(dividingBy: step)
        let firstY = viewport.y.truncatingRemainder(dividingBy: step)
        let colour = dark ? Color.white.opacity(0.13) : Color.black.opacity(0.13)
        for x in stride(from: firstX - step, through: size.width + step, by: step) {
            for y in stride(from: firstY - step, through: size.height + step, by: step) {
                context.fill(
                    Path(ellipseIn: CGRect(x: x - 0.85, y: y - 0.85, width: 1.7, height: 1.7)),
                    with: .color(colour)
                )
            }
        }
    }

    private func drawLive(context: GraphicsContext) {
        let ink = Color(cgColor: palette.cgColor(colour))
        let line = StrokeStyle(lineWidth: CGFloat(strokeSize.strokeWidth) * viewport.zoom,
                               lineCap: .round, lineJoin: .round)
        switch input {
        case .ink(let points):
            guard let start = points.first else { return }
            let path = CGMutablePath()
            DrawInk.livePath(start: start, points: points.dropFirst(), into: path)
            context.stroke(Path(path).applying(viewport.transform), with: .color(ink), style: line)
        case .shape(let start, let end):
            let frame = shape == .line || shape == .arrow
                ? DrawGeometry.lineFrame(from: start, to: end)
                : DrawGeometry.boxFrame(from: start, to: end)
            let path = DrawGeometry.shapePath(shape, frame: frame, corners: .square,
                                              width: CGFloat(strokeSize.strokeWidth))
            context.stroke(Path(path).applying(viewport.transform), with: .color(ink), style: line)
        case .marquee(let start, let end):
            let screenStart = viewport.screen(start)
            let screenEnd = viewport.screen(end)
            let rect = CGRect(x: screenStart.x, y: screenStart.y,
                              width: screenEnd.x - screenStart.x, height: screenEnd.y - screenStart.y).standardized
            context.fill(Path(rect), with: .color(.blue.opacity(0.07)))
            context.stroke(Path(rect), with: .color(.blue),
                           style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        default:
            break
        }
    }

    private var selectedObjects: [DrawObject] { objects.filter { selection.contains($0.id) } }

    private var displayedSelection: [DrawObject] {
        switch input {
        case .move(_, let offset):
            return selectedObjects.map { $0.translated(by: DrawPoint(x: offset.x, y: offset.y), id: $0.id) }
        case .resize(let resize):
            return resize.current
        default:
            return selectedObjects
        }
    }

    private var selectedBounds: CGRect? { DrawGeometry.union(displayedSelection) }

    private func selectionOverlay(in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if let bounds = selectedBounds, tool == .select {
                let box = viewport.screen(bounds).insetBy(dx: -4, dy: -4)
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: 1.5)
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
                ForEach(Array(handleLocations().enumerated()), id: \.offset) { _, spot in
                    Circle()
                        .fill(Color(uiColor: .systemBackground))
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                        .frame(width: 10, height: 10)
                        .position(spot.point)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func selectionActionBar(in size: CGSize) -> some View {
        Group {
            if let bounds = selectedBounds, tool == .select, input == nil, !selection.isEmpty {
                let rect = viewport.screen(bounds)
                let halfWidth = min(140, size.width / 2)
                let x = min(max(halfWidth, rect.midX), size.width - halfWidth)
                let y = min(max(134, rect.minY - 34), max(134, size.height - 125))
                HStack(spacing: 1) {
                    if selectionStyleOpen {
                        Button("Done") { selectionStyleOpen = false }
                            .fontWeight(.semibold)
                            .padding(.horizontal, 9)
                        ForEach(DrawColour.allCases, id: \.self) { choice in
                            colourButton(choice, isSelected: selectedStyleColour == choice) {
                                restyleSelection { $0.style.colour = choice }
                            }
                        }
                        Menu {
                            ForEach(DrawSize.allCases, id: \.self) { choice in
                                Button(choice.titleForDraw) { restyleSelection(size: choice) }
                            }
                            if selectedObjects.contains(where: { $0.content == .shape(.rectangle) }) {
                                Divider()
                                Button("Square corners") { restyleSelection(corners: .square) }
                                Button("Rounded corners") { restyleSelection(corners: .rounded) }
                            }
                        } label: {
                            Image(systemName: "lineweight")
                                .frame(width: 32, height: 40)
                        }
                        .accessibilityLabel("Size and corners")
                    } else {
                        Button("Style") { selectionStyleOpen = true }
                        Button("Duplicate") { duplicateSelection() }
                        Button("Delete", role: .destructive) { deleteSelection() }
                            .foregroundStyle(.red)
                        Menu {
                            Button(addToSelection ? "Finish selecting" : "Select more") {
                                addToSelection.toggle()
                            }
                            Button("Select all") { selection = Set(objects.map(\.id)) }
                            Button("Bring to front") { reorderSelection(front: true) }
                            Button("Send to back") { reorderSelection(front: false) }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 30, height: 40)
                        }
                        .accessibilityLabel("More selection actions")
                    }
                }
                .font(.system(size: 14, weight: .medium))
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .frame(height: 48)
                .modifier(PhoneDrawCapsuleBackground(solid: reduceTransparency))
                .fixedSize(horizontal: true, vertical: false)
                .position(x: x, y: y)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func colourButton(_ choice: DrawColour, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(Color(cgColor: palette.cgColor(choice)))
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: isSelected ? 2 : 0).padding(-3))
                .frame(width: 32, height: 42)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(choice.rawValue.capitalized)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Input

    private func beginInput(at screen: CGPoint) {
        if strip != nil { strip = nil }
        if textEdit != nil { finishTextEditing() }
        let point = viewport.world(screen)
        switch tool {
        case .pen:
            selection.removeAll()
            input = .ink([point])
        case .eraser:
            selection.removeAll()
            input = .erase(removed: [], last: point)
            erase(at: point)
        case .shape:
            selection.removeAll()
            input = .shape(start: point, end: point)
        case .text:
            if let hit = DrawGeometry.pick(objects, at: point, tolerance: 8 / viewport.zoom),
               case .text = hit.content {
                editText(hit)
            } else {
                editText(at: point)
            }
        case .select:
            if let spot = handleLocations().min(by: {
                hypot($0.point.x - screen.x, $0.point.y - screen.y) <
                hypot($1.point.x - screen.x, $1.point.y - screen.y)
            }), hypot(spot.point.x - screen.x, spot.point.y - screen.y) <= 18 {
                let chosen = selectedObjects
                if !chosen.isEmpty {
                    input = .resize(PhoneDrawResize(handle: spot.handle, from: point,
                                                    originals: chosen, current: chosen))
                }
            } else if let hit = DrawGeometry.pick(objects, at: point, tolerance: 8 / viewport.zoom) {
                if addToSelection {
                    if !selection.insert(hit.id).inserted { selection.remove(hit.id) }
                } else if !selection.contains(hit.id) {
                    selection = [hit.id]
                }
                if selection.contains(hit.id) { input = .move(start: point, offset: .zero) }
            } else {
                if !addToSelection { selection.removeAll() }
                input = .marquee(start: point, end: point)
            }
        }
        selectionStyleOpen = false
    }

    private func moveInput(to screen: CGPoint) {
        let world = viewport.world(screen)
        switch input {
        case .ink(var points):
            if let last = points.last, hypot(world.x - last.x, world.y - last.y) < 0.25 { return }
            points.append(world)
            input = .ink(points)
        case .erase:
            erase(at: world)
        case .shape(let start, _):
            input = .shape(start: start, end: world)
        case .move(let start, _):
            input = .move(start: start, offset: CGPoint(x: world.x - start.x, y: world.y - start.y))
        case .marquee(let start, _):
            input = .marquee(start: start, end: world)
        case .resize(var resize):
            let delta = CGPoint(x: world.x - resize.from.x, y: world.y - resize.from.y)
            resize.current = resized(resize.originals, handle: resize.handle, delta: delta)
            input = .resize(resize)
        case nil:
            break
        }
    }

    private func finishInput() {
        guard let finished = input else { return }
        input = nil
        switch finished {
        case .ink(let points):
            let smooth = DrawInk.smooth(points)
            guard !smooth.isEmpty else { return }
            let new = DrawObject(frame: DrawGeometry.strokeFrame(smooth), zIndex: nextZ,
                                 style: DrawStyle(colour: colour, size: strokeSize),
                                 content: .stroke(smooth))
            command(.put([new]))
        case .erase(let removed, _):
            if !removed.isEmpty { command(.remove(Array(removed))) }
        case .shape(let start, let end):
            guard hypot(end.x - start.x, end.y - start.y) * viewport.zoom >= 4 else { return }
            let frame = shape == .line || shape == .arrow
                ? DrawGeometry.lineFrame(from: start, to: end)
                : DrawGeometry.boxFrame(from: start, to: end)
            let new = DrawObject(frame: frame, zIndex: nextZ,
                                 style: DrawStyle(colour: colour, size: strokeSize),
                                 content: .shape(shape))
            command(.put([new]))
            tool = .select
        case .move(_, let offset):
            guard hypot(offset.x, offset.y) * viewport.zoom > 3 else { return }
            let translated = selectedObjects.map {
                $0.translated(by: DrawPoint(x: offset.x, y: offset.y), id: $0.id)
            }
            command(.put(translated))
        case .marquee(let start, let end):
            let rect = CGRect(x: start.x, y: start.y,
                              width: end.x - start.x, height: end.y - start.y).standardized
            if max(rect.width, rect.height) * viewport.zoom > 4 {
                let matched = objects.filter { DrawGeometry.bounds($0).intersects(rect) }.map(\.id)
                if addToSelection { selection.formUnion(matched) }
                else { selection = Set(matched) }
            }
        case .resize(let resize):
            if resize.current != resize.originals { command(.put(resize.current)) }
        }
    }

    private func cancelInput() { input = nil }

    private func doubleTap(at screen: CGPoint) {
        guard tool == .select else { return }
        let point = viewport.world(screen)
        if let hit = DrawGeometry.pick(objects, at: point, tolerance: 8 / viewport.zoom),
           case .text = hit.content {
            editText(hit)
        }
    }

    private func erase(at current: CGPoint) {
        guard case .erase(var removed, let previous) = input else { return }
        let steps = max(1, Int((hypot(current.x - previous.x, current.y - previous.y) *
                               viewport.zoom / 4).rounded(.up)))
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let p = CGPoint(x: previous.x + (current.x - previous.x) * t,
                            y: previous.y + (current.y - previous.y) * t)
            for object in objects where !removed.contains(object.id) {
                if case .stroke = object.content,
                   DrawGeometry.hits(object, p, tolerance: 5 / viewport.zoom) {
                    removed.insert(object.id)
                }
            }
        }
        input = .erase(removed: removed, last: current)
    }

    // MARK: Selection and transforms

    private var nextZ: Int64 { (objects.map(\.zIndex).max() ?? 0) + 1 }

    private func handleLocations() -> [(handle: PhoneDrawHandle, point: CGPoint)] {
        guard let bounds = selectedBounds, !selection.isEmpty else { return [] }
        if displayedSelection.count == 1, let object = displayedSelection.first {
            if case .shape(let kind) = object.content, kind == .line || kind == .arrow {
                let (start, end) = DrawGeometry.endpoints(object.frame)
                return [(.start, viewport.screen(start)), (.end, viewport.screen(end))]
            }
            if case .text = object.content {
                let rect = viewport.screen(bounds).insetBy(dx: -4, dy: -4)
                return [(.left, CGPoint(x: rect.minX, y: rect.midY)),
                        (.right, CGPoint(x: rect.maxX, y: rect.midY))]
            }
        }
        let rect = viewport.screen(bounds).insetBy(dx: -4, dy: -4)
        return [(.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
                (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
                (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
                (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY))]
    }

    private func resized(_ originals: [DrawObject], handle: PhoneDrawHandle, delta: CGPoint) -> [DrawObject] {
        guard let first = originals.first else { return [] }
        if originals.count == 1 {
            switch handle {
            case .start, .end:
                var copy = first
                let (a, b) = DrawGeometry.endpoints(first.frame)
                let shifted = handle == .start
                    ? CGPoint(x: a.x + delta.x, y: a.y + delta.y)
                    : CGPoint(x: b.x + delta.x, y: b.y + delta.y)
                copy.frame = handle == .start ? DrawGeometry.lineFrame(from: shifted, to: b)
                                              : DrawGeometry.lineFrame(from: a, to: shifted)
                return [copy]
            case .left, .right:
                var copy = first
                let width = max(4, CGFloat(first.frame.width) + (handle == .right ? delta.x : -delta.x))
                if handle == .left { copy.frame.x = first.frame.x + first.frame.width - width }
                copy.textWidth = width
                measureText(&copy)
                return [copy]
            default:
                break
            }
        }
        guard let bounds = DrawGeometry.union(originals) else { return originals }
        let left = handle == .topLeft || handle == .bottomLeft
        let top = handle == .topLeft || handle == .topRight
        let anchor = CGPoint(x: left ? bounds.maxX : bounds.minX,
                             y: top ? bounds.maxY : bounds.minY)
        let sx = max(4, bounds.width + (left ? -delta.x : delta.x)) / max(bounds.width, 0.001)
        let sy = max(4, bounds.height + (top ? -delta.y : delta.y)) / max(bounds.height, 0.001)
        let uniform = originals.count > 1 || first.isImage || bounds.width < 0.001 || bounds.height < 0.001
        let scale = abs(sx - 1) >= abs(sy - 1) ? sx : sy
        let xScale = uniform ? scale : sx
        let yScale = uniform ? scale : sy
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: anchor.x + (p.x - anchor.x) * xScale,
                    y: anchor.y + (p.y - anchor.y) * yScale)
        }
        return originals.map { original in
            var copy = original
            let rect = DrawGeometry.frame(original.frame)
            switch original.content {
            case .stroke(let points):
                let converted = points.map {
                    let p = map(CGPoint(x: $0.x, y: $0.y))
                    return DrawPoint(x: p.x, y: p.y)
                }
                copy.content = .stroke(converted)
                copy.frame = DrawGeometry.strokeFrame(converted)
            case .shape(let kind) where kind == .line || kind == .arrow:
                let (a, b) = DrawGeometry.endpoints(original.frame)
                copy.frame = DrawGeometry.lineFrame(from: map(a), to: map(b))
            case .text:
                let origin = map(rect.origin)
                copy.frame.x = origin.x
                copy.frame.y = origin.y
                let amount = min(xScale, yScale)
                copy.textScale = (original.textScale ?? 1) * amount
                copy.textWidth = original.textWidth.map { $0 * amount }
                measureText(&copy)
            default:
                let a = map(CGPoint(x: rect.minX, y: rect.minY))
                let b = map(CGPoint(x: rect.maxX, y: rect.maxY))
                copy.frame = DrawGeometry.boxFrame(from: a, to: b)
            }
            return copy
        }
    }

    private func duplicateSelection() {
        var z = nextZ
        let copies = selectedObjects.map { original -> DrawObject in
            let shifted = original.translated(by: DrawPoint(x: 12 / viewport.zoom,
                                                            y: 12 / viewport.zoom))
            var copy = shifted
            copy.zIndex = z
            z += 1
            return copy
        }
        guard !copies.isEmpty else { return }
        command(.put(copies))
        selection = Set(copies.map(\.id))
    }

    private func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = Array(selection)
        selection.removeAll()
        selectionStyleOpen = false
        command(.remove(ids))
    }

    private func reorderSelection(front: Bool) {
        let chosen = selectedObjects
        guard !chosen.isEmpty else { return }
        var z = front ? nextZ : (objects.map(\.zIndex).min() ?? 0) - Int64(chosen.count)
        command(.put(chosen.map { original in
            var copy = original
            copy.zIndex = z
            z += 1
            return copy
        }))
    }

    private var selectedStyleColour: DrawColour? {
        let styled = selectedObjects.filter { !$0.isImage }
        guard let first = styled.first, styled.allSatisfy({ $0.style.colour == first.style.colour }) else { return nil }
        return first.style.colour
    }

    private func restyleSelection(_ update: (inout DrawObject) -> Void) {
        let changed = selectedObjects.filter { !$0.isImage }.map { original -> DrawObject in
            var copy = original
            update(&copy)
            if case .text = copy.content { measureText(&copy) }
            return copy
        }
        if !changed.isEmpty { command(.put(changed)) }
    }

    private func restyleSelection(size: DrawSize) { restyleSelection { $0.style.size = size } }
    private func restyleSelection(corners: DrawCorners) {
        restyleSelection { if $0.content == .shape(.rectangle) { $0.style.corners = corners } }
    }

    // MARK: Text

    private func editText(at point: CGPoint) {
        textEdit = PhoneDrawTextEdit(
            id: UUID(), origin: CGPoint(x: point.x, y: point.y - CGFloat(textSize.textSize) * DrawText.clickLift),
            text: "", style: DrawStyle(colour: colour, size: textSize), stored: false, original: nil
        )
    }

    private func editText(_ object: DrawObject) {
        textEdit = PhoneDrawTextEdit(id: object.id,
                                     origin: CGPoint(x: object.frame.x, y: object.frame.y),
                                     text: object.text, style: object.style, stored: true, original: object)
    }

    private var textEditor: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Text on canvas")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { textEdit?.text ?? "" },
                    set: { updateText($0) }
                ))
                .font(.system(size: CGFloat(textEdit?.style.size.textSize ?? 14)))
                .focused($textFocused)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 18))
                .accessibilityIdentifier("phone-draw-text-editor")
            }
            .padding(16)
            .navigationTitle("Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finishTextEditing() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { textFocused = true }
    }

    private func updateText(_ value: String) {
        guard var edit = textEdit, edit.text != value else { return }
        edit.text = value
        textEdit = edit
        guard !value.isEmpty || edit.stored else { return }
        var object = edit.original ?? DrawObject(
            id: edit.id,
            frame: DrawFrame(x: edit.origin.x, y: edit.origin.y),
            zIndex: nextZ,
            style: edit.style,
            content: .text(value)
        )
        object.content = .text(value)
        measureText(&object)
        command(.put([object]))
        edit.original = object
        edit.stored = true
        textEdit = edit
    }

    private func measureText(_ object: inout DrawObject) {
        let size = DrawText.size(of: object.text,
                                 fontSize: CGFloat(object.style.size.textSize),
                                 width: object.textWidth.map { CGFloat($0) },
                                 scale: CGFloat(object.textScale ?? 1))
        object.frame.width = size.width
        object.frame.height = size.height
    }

    private func finishTextEditing() {
        if let edit = textEdit, edit.stored, edit.text.isEmpty {
            command(.remove([edit.id]))
        }
        textEdit = nil
        textFocused = false
    }

    // MARK: Viewport

    private func clearBoardRect() -> CGRect {
        CGRect(x: 16, y: 128, width: max(1, boardSize.width - 32),
               height: max(1, boardSize.height - 238))
    }

    private func fitCurrentCanvas() {
        guard boardSize.width > 0, boardSize.height > 0 else { return }
        viewport = DrawViewport.fit(DrawGeometry.union(objects), in: clearBoardRect())
        needsInitialFit = false
        userMovedBoard = false
    }

    private var lost: Bool {
        userMovedBoard && !objects.isEmpty &&
        !viewport.anyInView(objects.map { DrawGeometry.bounds($0) }, clear: clearBoardRect())
    }

    private var shouldShowZoom: Bool { zoomFlashing || lost }

    private func flashZoom() {
        zoomFlashing = true
        zoomFlashTask?.cancel()
        zoomFlashTask = Task {
            try? await Task.sleep(for: .seconds(1.1))
            if !Task.isCancelled { zoomFlashing = false }
        }
    }

    private var zoomPill: some View {
        Button {
            fitCurrentCanvas()
            flashZoom()
        } label: {
            Text(lost && !zoomFlashing ? "Fit" : "\(Int((viewport.zoom * 100).rounded())) %")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .modifier(PhoneDrawCapsuleBackground(solid: reduceTransparency))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Zoom to fit")
        .accessibilityIdentifier("phone-draw-zoom")
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Controls

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Button {
                canvasFilter = ""
                showCanvasPicker = true
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(canvas?.name ?? "Canvas")
                        .font(.system(size: 30, weight: .bold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .minimumScaleFactor(0.8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch canvas, \(canvas?.name ?? "Canvas")")
            .accessibilityIdentifier("phone-draw-title")

            Spacer(minLength: 4)

            Menu {
                Button("Rename", systemImage: "pencil") {
                    renameDraft = canvas?.name ?? ""
                    showRename = true
                }
                Button("Tags…", systemImage: "number") {
                    tagsDraft = canvas?.tags.joined(separator: ", ") ?? ""
                    showTags = true
                }
                Button("Switch canvas", systemImage: "square.stack") {
                    canvasFilter = ""
                    showCanvasPicker = true
                }
                Button("Duplicate", systemImage: "plus.square.on.square") { duplicateCanvas() }
                Menu("Export…", systemImage: "square.and.arrow.up") {
                    Button("PNG image") { export(.png) }
                    Button("PDF document") { export(.pdf) }
                }
                Button("Copy as Image", systemImage: "doc.on.doc") { copyAsImage() }
                Divider()
                Button("Delete", systemImage: "trash", role: .destructive) {
                    confirmDelete = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .modifier(PhoneDrawCapsuleBackground(solid: reduceTransparency))
            }
            .disabled(exporting)
            .accessibilityLabel("Canvas actions")
            .accessibilityIdentifier("phone-draw-menu")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(PhoneDrawTool.allCases, id: \.self) { choice in
                        if strip == .shape && choice == .shape {
                            toolVariantsForShape
                        } else if strip == .pen && choice == .pen {
                            toolVariantsForSize(text: false)
                        } else if strip == .text && choice == .text {
                            toolVariantsForSize(text: true)
                        } else {
                            toolButton(choice)
                        }
                    }
                    if strip == .colour {
                        HStack(spacing: 0) {
                            ForEach(DrawColour.allCases, id: \.self) { choice in
                                colourButton(choice, isSelected: colour == choice) {
                                    colour = choice
                                    strip = nil
                                }
                            }
                        }
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    } else {
                        Button {
                            strip = strip == .colour ? nil : .colour
                        } label: {
                            Circle()
                                .fill(Color(cgColor: palette.cgColor(colour)))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(.background, lineWidth: 2).padding(-2))
                                .frame(width: 40, height: 48)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Ink colour")
                        .accessibilityIdentifier("phone-draw-swatch")
                    }
                    if strip == nil {
                        Button { undo() } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .frame(width: 40, height: 48)
                                .contentShape(Rectangle())
                        }
                        .disabled(!state.draw.canUndo(on: activeID))
                        .accessibilityLabel("Undo")
                        .accessibilityIdentifier("phone-draw-undo")
                        .keyboardShortcut("z", modifiers: .command)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 20))
                .foregroundStyle(.primary)
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: 56)
            .modifier(PhoneDrawCapsuleBackground(solid: reduceTransparency))

            if strip == nil {
                Spacer(minLength: 0)
                Button { newCanvas() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 21, weight: .medium))
                        .frame(width: 56, height: 56)
                        .modifier(PhoneDrawCapsuleBackground(solid: reduceTransparency))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New canvas")
                .accessibilityIdentifier("phone-draw-new")
            }
        }
    }

    private func toolButton(_ choice: PhoneDrawTool) -> some View {
        Button {
            if choice == .shape {
                tool = .shape
                strip = strip == .shape ? nil : .shape
            } else if choice == .pen || choice == .text {
                let target: PhoneDrawStrip = choice == .pen ? .pen : .text
                if tool == choice { strip = strip == target ? nil : target }
                else { tool = choice; strip = nil }
            } else {
                tool = choice
                strip = nil
            }
            if tool != .select { selection.removeAll() }
            selectionStyleOpen = false
        } label: {
            Image(systemName: choice == .shape ? shape.symbolForDraw : choice.symbol)
                .font(.system(size: 20, weight: .regular))
                .frame(width: 40, height: 48)
                .background(tool == choice ? Color.primary.opacity(0.09) : .clear, in: Capsule())
                .contentShape(Rectangle())
        }
        .accessibilityLabel(choice.rawValue.capitalized)
        .accessibilityAddTraits(tool == choice ? .isSelected : [])
        .accessibilityIdentifier("phone-draw-\(choice.rawValue)")
    }

    private var toolVariantsForShape: some View {
        HStack(spacing: 0) {
            ForEach(DrawShape.allCases, id: \.self) { choice in
                Button {
                    shape = choice
                    strip = nil
                    tool = .shape
                } label: {
                    Image(systemName: choice.symbolForDraw)
                        .frame(width: 39, height: 44)
                        .background(shape == choice ? Color.primary.opacity(0.1) : .clear, in: Capsule())
                }
                .accessibilityLabel(choice.rawValue.capitalized)
                .accessibilityAddTraits(shape == choice ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private func toolVariantsForSize(text: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(DrawSize.allCases, id: \.self) { choice in
                Button {
                    if text { textSize = choice } else { strokeSize = choice }
                    strip = nil
                } label: {
                    Group {
                        if text {
                            Text("A").font(.system(size: CGFloat(choice.textSize), weight: .semibold))
                        } else {
                            Circle().fill(Color.primary)
                                .frame(width: CGFloat(choice.strokeWidth * 3 + 3),
                                       height: CGFloat(choice.strokeWidth * 3 + 3))
                        }
                    }
                    .frame(width: 42, height: 44)
                    .background((text ? textSize : strokeSize) == choice ?
                                Color.primary.opacity(0.1) : .clear, in: Capsule())
                }
                .accessibilityLabel(choice.titleForDraw)
                .accessibilityAddTraits((text ? textSize : strokeSize) == choice ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private func saveNotice(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
            Text(message)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let pending = state.draw.pendingEdits[activeID] {
                Button("Retry") {
                    switch pending.outcome {
                    case .held: handle(state.draw.reconcile(on: activeID))
                    case .retry: handle(state.draw.retry(on: activeID))
                    default: break
                    }
                    refreshSnapshot()
                }
                .font(.footnote.weight(.semibold))
            } else {
                Button("Dismiss") { issue = nil }
                    .font(.footnote.weight(.semibold))
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.orange.opacity(0.45)))
    }

    private var canvasPicker: some View {
        NavigationStack {
            List {
                ForEach(((try? state.draw.library()) ?? []).filter {
                    canvasFilter.isEmpty || $0.name.localizedStandardContains(canvasFilter) ||
                    $0.tags.contains(where: { $0.localizedStandardContains(canvasFilter) })
                }) { candidate in
                    Button {
                        showCanvasPicker = false
                        openCanvas(candidate.id, fitting: true)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "scribble.variable")
                                .foregroundStyle(.secondary)
                            Text(candidate.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if candidate.id == activeID { Image(systemName: "checkmark") }
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
            .searchable(text: $canvasFilter, prompt: "Find a canvas")
            .navigationTitle("Canvases")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showCanvasPicker = false }
                }
            }
        }
    }

    // MARK: Store commands

    private func openCanvas(_ id: UUID, fitting: Bool) {
        if activeID != id { finishInput(); finishTextEditing(); queueThumbnail(immediately: true) }
        activeID = id
        do {
            let snapshot = try state.draw.open(id)
            canvas = snapshot.canvas
            objects = snapshot.objects.filter { $0.deletedAt == nil }
            selection.removeAll()
            strip = nil
            input = nil
            textEdit = nil
            issue = nil
            if let pending = state.draw.pendingEdits[id] {
                switch pending.outcome {
                case .retry(let message), .held(let message):
                    issue = message.isEmpty ? "This drawing has an unsaved change." : message
                default: break
                }
            }
            revision += 1
            if fitting {
                needsInitialFit = true
                fitCurrentCanvas()
            }
        } catch {
            canvas = nil
            objects = []
            issue = "Could not open this canvas: \(error.localizedDescription)"
            state.errorMessage = issue
        }
    }

    private func refreshSnapshot() {
        guard let snapshot = try? state.draw.open(activeID) else { return }
        canvas = snapshot.canvas
        let current = snapshot.objects.filter { $0.deletedAt == nil }
        if current != objects { revision &+= 1 }
        objects = current
        selection = selection.intersection(Set(objects.map(\.id)))
    }

    private func command(_ command: DrawCommand) {
        handle(state.draw.perform(command, on: activeID))
        refreshSnapshot()
    }

    private func handle(_ result: DrawSaveResult) {
        switch result {
        case .saved:
            issue = nil
            state.refresh()
            queueThumbnail()
        case .unchanged:
            break
        case .retry(let message):
            issue = message.isEmpty ? "This drawing has an unsaved change." : message
            state.errorMessage = issue
        case .held(let message):
            issue = message.isEmpty ? "This drawing needs a save reconciliation." : message
            state.errorMessage = issue
        }
    }

    private func undo() {
        guard state.draw.canUndo(on: activeID) else { return }
        handle(state.draw.undo(on: activeID))
        refreshSnapshot()
    }

    private func newCanvas() {
        finishInput()
        finishTextEditing()
        queueThumbnail(immediately: true)
        let created = state.draw.create()
        openCanvas(created.id, fitting: true)
        tool = .pen
        state.refresh()
    }

    private func duplicateCanvas() {
        do {
            guard let copy = try state.draw.duplicate(activeID) else {
                issue = "This canvas could not be duplicated."
                return
            }
            openCanvas(copy.id, fitting: true)
            state.refresh()
        } catch {
            issue = "Could not duplicate the canvas: \(error.localizedDescription)"
        }
    }

    private func deleteCanvas() {
        let old = activeID
        let result = state.draw.perform(.deleteCanvas, on: old)
        handle(result)
        guard result.isSaved else { refreshSnapshot(); return }
        if let next = try? state.draw.library().first {
            openCanvas(next.id, fitting: true)
        } else {
            let fresh = state.draw.create()
            openCanvas(fresh.id, fitting: true)
        }
        state.refresh()
    }

    private func queueThumbnail(immediately: Bool = false) {
        let target = activeID
        let snapshot = objects
        let dark = dark
        thumbnailTask?.cancel()
        thumbnailTask = Task { @MainActor in
            if !immediately {
                try? await Task.sleep(for: .seconds(1.5))
            }
            guard !Task.isCancelled else { return }
            let image = await Task.detached(priority: .utility) {
                DrawThumbnail.render(snapshot, dark: dark)
            }.value
            guard !Task.isCancelled else { return }
            let outcome = state.draw.perform(.thumbnail(image, dark: image == nil ? nil : dark), on: target)
            if target == activeID {
                switch outcome {
                case .retry, .held: handle(outcome)
                default: break
                }
            }
        }
    }

    // MARK: Share / copy (the originals in DrawObject are never modified)

    private func export(_ format: DrawExportFormat) {
        guard !objects.isEmpty else {
            issue = "This canvas is empty."
            return
        }
        exporting = true
        let snapshot = objects, dark = dark
        Task {
            let data = await Task.detached(priority: .userInitiated) {
                DrawExport.render(snapshot, format: format, dark: dark)
            }.value
            exporting = false
            guard let data else { issue = "Could not export this canvas."; return }
            let ext = format == .png ? "png" : "pdf"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Attic-Canvas-\(UUID().uuidString)")
                .appendingPathExtension(ext)
            do {
                try data.write(to: url, options: .atomic)
                share = PhoneDrawShare(url: url)
            } catch {
                issue = "Could not prepare the export: \(error.localizedDescription)"
            }
        }
    }

    private func copyAsImage() {
        guard !objects.isEmpty else {
            issue = "This canvas is empty."
            return
        }
        exporting = true
        let snapshot = objects, dark = dark
        Task {
            let bytes = await Task.detached(priority: .userInitiated) {
                DrawExport.render(snapshot, format: .png, dark: dark)
            }.value
            exporting = false
            guard let bytes, let image = UIImage(data: bytes) else {
                issue = "Could not copy the canvas image."
                return
            }
            UIPasteboard.general.image = image
        }
    }
}

// MARK: Local presentation and input types

private enum PhoneDrawTool: String, CaseIterable {
    case select, pen, eraser, text, shape
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .pen: "pencil.tip"
        case .eraser: "eraser"
        case .text: "textformat"
        case .shape: "square"
        }
    }
}

private enum PhoneDrawStrip { case pen, text, shape, colour }

private extension DrawShape {
    var symbolForDraw: String {
        switch self {
        case .rectangle: "rectangle"
        case .ellipse: "oval"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        }
    }
}

private extension DrawSize {
    var titleForDraw: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

private enum PhoneDrawHandle { case topLeft, topRight, bottomLeft, bottomRight, start, end, left, right }

private struct PhoneDrawResize {
    let handle: PhoneDrawHandle
    let from: CGPoint
    let originals: [DrawObject]
    var current: [DrawObject]
}

private enum PhoneDrawInput {
    case ink([CGPoint])
    case erase(removed: Set<UUID>, last: CGPoint)
    case shape(start: CGPoint, end: CGPoint)
    case move(start: CGPoint, offset: CGPoint)
    case marquee(start: CGPoint, end: CGPoint)
    case resize(PhoneDrawResize)
}

private struct PhoneDrawTextEdit: Identifiable {
    let id: UUID
    let origin: CGPoint
    var text: String
    let style: DrawStyle
    var stored: Bool
    var original: DrawObject?
}

private struct PhoneDrawShare: Identifiable {
    let id = UUID()
    let url: URL
}

private struct PhoneDrawShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct PhoneDrawCapsuleBackground: ViewModifier {
    let solid: Bool
    func body(content: Content) -> some View {
        content
            .background {
                Capsule()
                    .fill(solid ? AnyShapeStyle(Color(uiColor: .secondarySystemBackground))
                                : AnyShapeStyle(.regularMaterial))
            }
            .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

@MainActor @Observable
private final class PhoneDrawRasterState {
    var image: CGImage?
    var key: DrawRasterKey?
    @ObservationIgnored private lazy var renderer = DrawLatestRenderer<DrawRasterRequest, DrawRasterImage>(
        work: { request, cancelled in DrawRaster.render(request, cancelled: cancelled) },
        install: { [weak self] request, output in
            self?.key = request.key
            self?.image = output.image
        }
    )

    func request(_ request: DrawRasterRequest) { renderer.request(request) }
    func cancel() { renderer.cancel() }
}

/// A transparent UIKit input layer. Coalesced Apple Pencil/finger samples feed
/// DrawInk; two-finger gestures cancel the pending mark and change the viewport.
private struct PhoneDrawTouchSurface: UIViewRepresentable {
    let began: (CGPoint) -> Void
    let moved: ([CGPoint]) -> Void
    let ended: (CGPoint, Int) -> Void
    let cancelled: () -> Void
    let panned: (CGPoint) -> Void
    let pinched: (CGFloat, CGPoint) -> Void

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.isOpaque = false
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.accessibilityTraits = [.allowsDirectInteraction]
        view.isAccessibilityElement = true
        let pinch = UIPinchGestureRecognizer(target: view, action: #selector(TouchView.pinched(_:)))
        let pan = UIPanGestureRecognizer(target: view, action: #selector(TouchView.panned(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.cancelsTouchesInView = false
        pinch.cancelsTouchesInView = false
        pinch.delegate = view
        pan.delegate = view
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) {
        view.began = began
        view.moved = moved
        view.ended = ended
        view.cancelled = cancelled
        view.pan = panned
        view.pinch = pinched
    }

    final class TouchView: UIView, UIGestureRecognizerDelegate {
        var began: ((CGPoint) -> Void)?
        var moved: (([CGPoint]) -> Void)?
        var ended: ((CGPoint, Int) -> Void)?
        var cancelled: (() -> Void)?
        var pan: ((CGPoint) -> Void)?
        var pinch: ((CGFloat, CGPoint) -> Void)?
        private weak var active: UITouch?
        private var multitouch = false

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if activeFingers(in: event) >= 2 {
                if active != nil { cancelled?() }
                active = nil
                multitouch = true
                return
            }
            guard !multitouch else { return }
            // A resting finger must not block the Pencil when it arrives.
            if active?.type == .direct, touches.contains(where: { $0.type == .pencil }) {
                cancelled?()
                active = nil
            }
            guard active == nil,
                  let touch = touches.first(where: { $0.type == .pencil }) ??
                              touches.first(where: { $0.type == .direct }) else { return }
            active = touch
            began?(touch.location(in: self))
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let active, touches.contains(active), !multitouch else { return }
            let samples = event?.coalescedTouches(for: active) ?? [active]
            moved?(samples.map { $0.location(in: self) })
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let active, touches.contains(active), !multitouch {
                ended?(active.location(in: self), active.tapCount)
                self.active = nil
            }
            if activeFingers(in: event) == 0 { multitouch = false }
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let active, touches.contains(active) {
                cancelled?()
                self.active = nil
            }
            if activeFingers(in: event) == 0 { multitouch = false }
        }

        private func activeFingers(in event: UIEvent?) -> Int {
            guard let all = event?.allTouches else { return 0 }
            return all.filter {
                $0.type == .direct && $0.phase != .ended && $0.phase != .cancelled
            }.count
        }

        @objc func panned(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began {
                cancelled?()
                active = nil
                multitouch = true
            }
            if recognizer.state == .changed {
                pan?(recognizer.translation(in: self))
                recognizer.setTranslation(.zero, in: self)
            }
            if recognizer.state == .ended || recognizer.state == .cancelled {
                recognizer.setTranslation(.zero, in: self)
                multitouch = false
            }
        }

        @objc func pinched(_ recognizer: UIPinchGestureRecognizer) {
            if recognizer.state == .began {
                cancelled?()
                active = nil
                multitouch = true
            }
            if recognizer.state == .changed {
                pinch?(recognizer.scale, recognizer.location(in: self))
                recognizer.scale = 1
            }
            if recognizer.state == .ended || recognizer.state == .cancelled {
                recognizer.scale = 1
                multitouch = false
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
