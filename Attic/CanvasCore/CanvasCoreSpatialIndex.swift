import Foundation

/// Fixed fanout R-tree. STR loading and quadratic splits keep all leaves at
/// one depth. The ID-to-leaf map makes removal independent of scene size.
final class CanvasCoreSpatialIndex {
    static let fanout = 8
    private final class Node {
        weak var parent: Node?
        var children: [Node] = []
        var entries: [CanvasCoreMetadata] = []
        var bounds: CanvasCoreBounds?
        let level: Int
        init(level: Int) { self.level = level }
        var count: Int { level == 0 ? entries.count : children.count }
        func refresh() {
            let boxes = level == 0 ? entries.map(\.bounds) : children.compactMap(\.bounds)
            bounds = boxes.first.map { first in boxes.dropFirst().reduce(first) { $0.union($1) } }
        }
    }
    private var root = Node(level: 0)
    private var leaves: [CanvasCoreID: Node] = [:]
    private(set) var generation: UInt64 = 0
    private(set) var lastQueryNodes = 0
    private(set) var lastMutationNodes = 0
    var count: Int { leaves.count }
    var height: Int { root.level + 1 }

    init(_ entries: [CanvasCoreMetadata] = []) throws { try bulkLoad(entries) }
    private func strGroups<T>(_ values: [T], bounds: (T) -> CanvasCoreBounds) -> [[T]] {
        guard !values.isEmpty else { return [] }
        let groups = Int(ceil(Double(values.count) / Double(Self.fanout)))
        let slices = Int(ceil(sqrt(Double(groups))))
        let sliceSize = Int(ceil(Double(groups) / Double(slices))) * Self.fanout
        let sorted = values.sorted { bounds($0).minX < bounds($1).minX }
        var result: [[T]] = []
        for start in stride(from: 0, to: sorted.count, by: sliceSize) {
            let slice = sorted[start..<min(start + sliceSize, sorted.count)].sorted { bounds($0).minY < bounds($1).minY }
            for index in stride(from: 0, to: slice.count, by: Self.fanout) {
                result.append(Array(slice[index..<min(index + Self.fanout, slice.count)]))
            }
        }
        return result
    }
    func bulkLoad(_ entries: [CanvasCoreMetadata]) throws {
        guard entries.allSatisfy({ $0.bounds.valid }), Set(entries.map(\.id)).count == entries.count else { throw CanvasCoreError.invalidGeometry }
        leaves.removeAll(); root = Node(level: 0)
        var layer = strGroups(entries, bounds: { $0.bounds }).map { group -> Node in
            let node = Node(level: 0); node.entries = group; node.refresh()
            for entry in group { leaves[entry.id] = node }; return node
        }
        if layer.isEmpty { layer = [root] }
        while layer.count > 1 {
            layer = strGroups(layer, bounds: { $0.bounds! }).map { group in
                let node = Node(level: group[0].level + 1); node.children = group
                for child in group { child.parent = node }; node.refresh(); return node
            }
        }
        root = layer[0]; generation &+= 1
    }
    func query(_ bounds: CanvasCoreBounds) -> [CanvasCoreMetadata] {
        lastQueryNodes = 0
        guard bounds.valid else { return [] }
        var result: [CanvasCoreMetadata] = []
        func visit(_ node: Node) {
            lastQueryNodes += 1
            guard node.bounds?.intersects(bounds) == true else { return }
            if node.level == 0 { result.append(contentsOf: node.entries.filter { $0.bounds.intersects(bounds) }) }
            else { for child in node.children { visit(child) } }
        }
        visit(root); return result
    }
    func topmost(in bounds: CanvasCoreBounds, exact: (CanvasCoreMetadata) -> Bool) -> CanvasCoreMetadata? {
        query(bounds).filter(exact).max {
            $0.rank == $1.rank ? $0.id.objectID.uuidString < $1.id.objectID.uuidString : $0.rank < $1.rank
        }
    }
    func entry(_ id: CanvasCoreID) -> CanvasCoreMetadata? { leaves[id]?.entries.first { $0.id == id } }

    func update(_ entry: CanvasCoreMetadata) throws {
        guard entry.bounds.valid else { throw CanvasCoreError.invalidGeometry }
        lastMutationNodes = 0
        removeInternal(entry.id)
        insert(entry, child: nil, at: 0)
        generation &+= 1
    }
    func remove(_ id: CanvasCoreID) {
        lastMutationNodes = 0
        guard leaves[id] != nil else { return }
        removeInternal(id); generation &+= 1
    }
    private func enlargement(_ node: Node, _ box: CanvasCoreBounds) -> Double {
        node.bounds.map { $0.union(box).area - $0.area } ?? box.area
    }
    private func insert(_ entry: CanvasCoreMetadata?, child: Node?, at level: Int) {
        let box = entry?.bounds ?? child!.bounds!
        while root.level < level {
            let parent = Node(level: root.level + 1); parent.children = [root]; root.parent = parent; parent.refresh(); root = parent
        }
        var node = root
        while node.level > level {
            lastMutationNodes += 1
            let next = node.children.min {
                let a = enlargement($0, box), b = enlargement($1, box)
                return a == b ? ($0.bounds?.area ?? 0) < ($1.bounds?.area ?? 0) : a < b
            }!
            node = next
        }
        if let entry { node.entries.append(entry); leaves[entry.id] = node }
        if let child { node.children.append(child); child.parent = node }
        adjust(node)
    }
    private func adjust(_ start: Node) {
        var current: Node? = start
        while let node = current {
            lastMutationNodes += 1; node.refresh()
            if node.count > Self.fanout {
                let sibling = split(node)
                if let parent = node.parent { parent.children.append(sibling); sibling.parent = parent }
                else {
                    let parent = Node(level: node.level + 1); parent.children = [node, sibling]
                    node.parent = parent; sibling.parent = parent; root = parent
                }
            }
            current = node.parent
        }
    }
    private func split(_ node: Node) -> Node {
        let sibling = Node(level: node.level)
        let entries = node.entries, children = node.children
        let boxes = node.level == 0 ? entries.map(\.bounds) : children.map { $0.bounds! }
        var seeds = (0, 1), waste = -Double.infinity
        for i in 0..<boxes.count { for j in (i + 1)..<boxes.count {
            let value = boxes[i].union(boxes[j]).area - boxes[i].area - boxes[j].area
            if value > waste { waste = value; seeds = (i, j) }
        } }
        var a = [seeds.0], b = [seeds.1], remaining = Set(boxes.indices).subtracting([seeds.0, seeds.1])
        var ab = boxes[seeds.0], bb = boxes[seeds.1]
        while !remaining.isEmpty {
            if a.count + remaining.count == 4 { a += remaining.sorted(); break }
            if b.count + remaining.count == 4 { b += remaining.sorted(); break }
            let next = remaining.max {
                abs(ab.union(boxes[$0]).area - ab.area - (bb.union(boxes[$0]).area - bb.area))
                    < abs(ab.union(boxes[$1]).area - ab.area - (bb.union(boxes[$1]).area - bb.area))
            }!
            remaining.remove(next)
            let ea = ab.union(boxes[next]).area - ab.area, eb = bb.union(boxes[next]).area - bb.area
            if ea < eb || (ea == eb && (ab.area < bb.area || (ab.area == bb.area && a.count <= b.count))) {
                a.append(next); ab = ab.union(boxes[next])
            } else { b.append(next); bb = bb.union(boxes[next]) }
        }
        if node.level == 0 {
            node.entries = a.map { entries[$0] }; sibling.entries = b.map { entries[$0] }
            for entry in sibling.entries { leaves[entry.id] = sibling }
        } else {
            node.children = a.map { children[$0] }; sibling.children = b.map { children[$0] }
            for child in sibling.children { child.parent = sibling }
        }
        node.refresh(); sibling.refresh(); return sibling
    }
    private func removeInternal(_ id: CanvasCoreID) {
        guard let leaf = leaves.removeValue(forKey: id) else { return }
        leaf.entries.removeAll { $0.id == id }
        var node = leaf
        var orphanEntries: [CanvasCoreMetadata] = [], orphanChildren: [Node] = []
        while let parent = node.parent {
            lastMutationNodes += 1
            if node.count < 4 {
                parent.children.removeAll { $0 === node }
                orphanEntries += node.entries; orphanChildren += node.children
                for child in node.children { child.parent = nil }
            } else { node.refresh() }
            node = parent
        }
        root.refresh()
        // Reinsert branches at their original levels, never flatten a subtree.
        for child in orphanChildren.sorted(by: { $0.level > $1.level }) {
            if root.count == 0 { root = child; root.parent = nil }
            else { insert(nil, child: child, at: child.level + 1) }
        }
        if root.count == 0 { root = Node(level: 0) }
        for entry in orphanEntries { insert(entry, child: nil, at: 0) }
        while root.level > 0 && root.children.count == 1 { root = root.children[0]; root.parent = nil }
    }
    /// Structural oracle support: verifies conservative boxes, fanout and
    /// equal leaf depth. No query or mutation invokes this exhaustive walk.
    func structurallyValid() -> Bool {
        var seen = Set<CanvasCoreID>()
        func check(_ node: Node) -> Bool {
            guard node.count <= Self.fanout else { return false }
            if node.level == 0 {
                for entry in node.entries {
                    guard seen.insert(entry.id).inserted, leaves[entry.id] === node,
                          node.bounds?.union(entry.bounds) == node.bounds else { return false }
                }
                return true
            }
            return node.children.allSatisfy {
                $0.parent === node && $0.level == node.level - 1
                    && node.bounds?.union($0.bounds!) == node.bounds && check($0)
            }
        }
        return check(root) && seen.count == leaves.count
    }
}

final class CanvasCoreReadingOrder {
    enum Stop: Equatable { case object(CanvasCoreID), drawing([CanvasCoreID]) }
    private(set) var stops: [Stop] = []
    private(set) var rebuilds = 0
    private var generation: UInt64?
    func refresh(_ metadata: [CanvasCoreMetadata], index: CanvasCoreSpatialIndex) {
        guard generation != index.generation else { return }
        let sorted = metadata.sorted {
            if $0.bounds.minY != $1.bounds.minY { return $0.bounds.minY < $1.bounds.minY }
            if $0.bounds.minX != $1.bounds.minX { return $0.bounds.minX < $1.bounds.minX }
            return $0.id.objectID.uuidString < $1.id.objectID.uuidString
        }
        let strokes = sorted.filter { $0.kind == .stroke }
        let positions = Dictionary(uniqueKeysWithValues: strokes.enumerated().map { ($1.id, $0) })
        var parents = Array(strokes.indices)
        func find(_ value: Int) -> Int {
            var current = value
            while parents[current] != current { parents[current] = parents[parents[current]]; current = parents[current] }
            return current
        }
        for (i, stroke) in strokes.enumerated() {
            for candidate in index.query(stroke.bounds.inflated(8)) where candidate.kind == .stroke {
                if let j = positions[candidate.id], stroke.bounds.inflated(4).intersects(candidate.bounds.inflated(4)) {
                    let a = find(i), b = find(j); if a != b { parents[b] = a }
                }
            }
        }
        var clusters: [Int: [CanvasCoreID]] = [:]
        for i in strokes.indices { clusters[find(i), default: []].append(strokes[i].id) }
        var emitted = Set<Int>(); stops = []
        for item in sorted {
            if let position = positions[item.id] {
                let root = find(position)
                if emitted.insert(root).inserted { stops.append(.drawing(clusters[root]!)) }
            } else { stops.append(.object(item.id)) }
        }
        generation = index.generation; rebuilds += 1
    }
    func enter(_ stop: Int) -> [CanvasCoreID] {
        guard stops.indices.contains(stop), case let .drawing(ids) = stops[stop] else { return [] }
        return ids
    }
    func exitDrawing(_ id: CanvasCoreID) -> Int? {
        stops.firstIndex { if case let .drawing(ids) = $0 { return ids.contains(id) }; return false }
    }
}
