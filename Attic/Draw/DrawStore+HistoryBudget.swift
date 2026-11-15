import Foundation

/// The pre-R6 budget is isolated here until the resident-only history change
/// removes it and its mechanism-specific tests together.
@MainActor
extension DrawStore {
    func boundEvictedHistories() {
        syncHistoryLedger()
        for id in ledgered.keys {
            if let history = histories[id], let entry = ledgered[id] {
                expireOversizedOffers(history: history, prints: entry.prints)
            }
        }
        let pinRevision = pins.revision
        guard saturatedLedgerGeneration != ledgerGeneration || saturatedPinRevision != pinRevision else { return }
        var protected = HistoryLedger()
        for (id, entry) in ledgered {
            guard let history = histories[id] else { continue }
            for stack in [history.undo, history.redo] {
                if let first = stack.firstIndex(where: { pins.isPinned($0.id) }) {
                    for step in stack[first...] { if let print = entry.prints[step.id] { protected.add(print) } }
                }
            }
        }
        let budget = Self.maxEvictedHistoryBytes + protected.total
        struct Candidate {
            var canvas: UUID
            var undo: Int
            var redo: Int
            var freed: Int
            var steps: Int { undo + redo }
        }
        while evictedLedger.total > budget {
            let deficit = evictedLedger.total - budget
            var candidates: [Candidate] = []
            for (id, entry) in ledgered {
                guard let history = histories[id] else { continue }
                for (isUndo, stack) in [(true, history.undo), (false, history.redo)] {
                    let prefix = stack.prefix { !pins.isPinned($0.id) }
                    let prints = prefix.compactMap { entry.prints[$0.id] }
                    for (offset, freed) in evictedLedger.freedByPrefixes(prints).enumerated() {
                        candidates.append(Candidate(canvas: id, undo: isUndo ? offset + 1 : 0,
                            redo: isUndo ? 0 : offset + 1, freed: freed))
                    }
                }
                if !(history.undo + history.redo).contains(where: { pins.isPinned($0.id) }) {
                    candidates.append(Candidate(canvas: id, undo: history.undo.count, redo: history.redo.count,
                        freed: evictedLedger.freed(by: Array(entry.prints.values))))
                }
            }
            let sufficient = candidates.filter { $0.freed >= deficit }
            let selected: Candidate?
            if !sufficient.isEmpty {
                selected = sufficient.min {
                    if $0.steps != $1.steps { return $0.steps < $1.steps }
                    if $0.freed != $1.freed { return $0.freed < $1.freed }
                    return (evictedAt[$0.canvas] ?? 0) < (evictedAt[$1.canvas] ?? 0)
                }
            } else {
                selected = candidates.filter { $0.freed > 0 }.max {
                    if $0.freed != $1.freed { return $0.freed < $1.freed }
                    if $0.steps != $1.steps { return $0.steps > $1.steps }
                    return (evictedAt[$0.canvas] ?? 0) > (evictedAt[$1.canvas] ?? 0)
                }
            }
            guard let selected, var history = histories[selected.canvas], let entry = ledgered[selected.canvas] else { break }
            let removed = Array(history.undo.prefix(selected.undo)) + Array(history.redo.prefix(selected.redo))
            for step in removed { if let print = entry.prints[step.id] { evictedLedger.remove(print) } }
            history.undo.removeFirst(selected.undo); history.redo.removeFirst(selected.redo)
            if history.undo.isEmpty && history.redo.isEmpty {
                histories[selected.canvas] = nil
                ledgered[selected.canvas] = nil
                ledgerGeneration &+= 1
            } else {
                histories[selected.canvas] = history
                setLedgered(selected.canvas, history, measuring: entry)
            }
        }
        saturatedLedgerGeneration = ledgerGeneration
        saturatedPinRevision = pinRevision
    }
    func reconsiderReleasedOffers() {
        pins.acknowledgeReleaseChange()
        for id in histories.keys { capUndo(on: id) }
        boundEvictedHistories()
    }
    func removeLedgered(_ id: UUID) {
        guard let entry = ledgered.removeValue(forKey: id) else { return }
        for print in entry.prints.values { evictedLedger.remove(print) }
        ledgerGeneration &+= 1
    }
    struct LedgeredHistory {
        var steps: [Step]
        var prints: [UUID: StepFootprint]
        var fingerprint: HistoryFingerprint
    }
    struct HistoryFingerprint: Equatable {
        var undoCount: Int, redoCount: Int
        var undoFirst: UUID?, undoLast: UUID?, redoFirst: UUID?, redoLast: UUID?
        init(_ history: History) {
            undoCount = history.undo.count; redoCount = history.redo.count
            undoFirst = history.undo.first?.id; undoLast = history.undo.last?.id
            redoFirst = history.redo.first?.id; redoLast = history.redo.last?.id
        }
    }
    func setLedgered(_ key: UUID, _ history: History, measuring earlier: LedgeredHistory? = nil) {
        #if DEBUG
        HistoryLedgerProbe.footprintSets += 1
        #endif
        var prints: [UUID: StepFootprint] = [:]
        for step in history.undo + history.redo {
            prints[step.id] = earlier?.prints[step.id] ?? HistoryLedger.measure(step)
        }
        let entry = LedgeredHistory(steps: history.undo + history.redo, prints: prints, fingerprint: HistoryFingerprint(history))
        if earlier == nil { for print in prints.values { evictedLedger.add(print) } }
        ledgered[key] = entry
        ledgerGeneration &+= 1
    }
    func syncHistoryLedger() {
        for (key, entry) in ledgered {
            if let history = histories[key], states[key] == nil, HistoryFingerprint(history) == entry.fingerprint { continue }
            for print in entry.prints.values { evictedLedger.remove(print) }
            ledgered[key] = nil
            ledgerGeneration &+= 1
        }
        for (key, history) in histories where states[key] == nil && ledgered[key] == nil {
            guard !history.undo.isEmpty || !history.redo.isEmpty else { continue }
            setLedgered(key, history)
        }
    }

    #if DEBUG
    func historyLedgerWorkForTesting(rebuild: Bool) -> (histories: Int, steps: Int, bytes: Int) {
        if !rebuild {
            boundEvictedHistories()
            return (ledgered.count, ledgered.values.reduce(0) { $0 + $1.steps.count }, evictedLedger.total)
        }
        var ledger = HistoryLedger()
        var count = 0, steps = 0
        for (id, history) in histories where states[id] == nil {
            count += 1
            for step in history.undo + history.redo { ledger.add(HistoryLedger.measure(step)); steps += 1 }
        }
        return (count, steps, ledger.total)
    }
    #endif

    struct LedgerBuffer: Hashable { let address: UInt; let count: Int }
    struct StepFootprint {
        var inline = 0
        var buffers: [(buffer: LedgerBuffer, size: Int, refs: Int)] = []
    }
    struct HistoryLedger {
        private var sizes: [LedgerBuffer: Int] = [:]
        private var references: [LedgerBuffer: Int] = [:]
        private(set) var total = 0
        mutating func add(_ print: StepFootprint) {
            total += print.inline
            for use in print.buffers {
                let held = references[use.buffer, default: 0]
                references[use.buffer] = held + use.refs
                if held == 0 { sizes[use.buffer] = use.size; total += use.size }
            }
        }
        mutating func remove(_ print: StepFootprint) {
            total -= print.inline
            for use in print.buffers {
                guard let held = references[use.buffer] else { continue }
                if held <= use.refs { references[use.buffer] = nil; total -= sizes.removeValue(forKey: use.buffer) ?? use.size }
                else { references[use.buffer] = held - use.refs }
            }
        }
        func freed(by prints: [StepFootprint]) -> Int {
            var freed = 0
            var local: [LedgerBuffer: Int] = [:]
            for print in prints {
                freed += print.inline
                for use in print.buffers { local[use.buffer, default: 0] += use.refs }
            }
            for (buffer, refs) in local where references[buffer] == refs { freed += sizes[buffer] ?? 0 }
            return freed
        }
        func freedByPrefixes(_ prints: [StepFootprint]) -> [Int] {
            var result: [Int] = [], local: [LedgerBuffer: Int] = [:], freed = 0
            for print in prints {
                freed += print.inline
                for use in print.buffers {
                    local[use.buffer, default: 0] += use.refs
                    if local[use.buffer] == references[use.buffer] { freed += sizes[use.buffer] ?? 0 }
                }
                result.append(freed)
            }
            return result
        }
        static func measure(_ step: Step) -> StepFootprint {
            #if DEBUG
            HistoryLedgerProbe.stepVisits += 1
            #endif
            var print = StepFootprint()
            var shared: [LedgerBuffer: (size: Int, refs: Int)] = [:]
            func record(_ buffer: LedgerBuffer?, _ bytes: Int) {
                guard let buffer else { print.inline += bytes; return }
                shared[buffer, default: (bytes, 0)].refs += 1
            }
            visit(step.before, record)
            visit(step.after, record)
            if let before = step.change.before { visit(before, record) }
            if let after = step.change.after { visit(after, record) }
            for object in step.change.objectsBefore.values { visit(object, record) }
            for object in step.change.objectsAfter.values { visit(object, record) }
            print.buffers = shared.map { (buffer: $0.key, size: $0.value.size, refs: $0.value.refs) }
            return print
        }
        private static func visit(_ canvas: DrawCanvas, _ body: (LedgerBuffer?, Int) -> Void) {
            body(nil, 256)
            visit(text: canvas.textIndex, body)
            if let data = canvas.thumbnail { body(buffer(data), data.count) }
        }
        private static func visit(_ object: DrawObject, _ body: (LedgerBuffer?, Int) -> Void) {
            #if DEBUG
            HistoryLedgerProbe.objectVisits += 1
            #endif
            body(nil, 256)
            switch object.content {
            case .stroke(let points): body(buffer(points), points.count * MemoryLayout<DrawPoint>.stride)
            case .text(let text): visit(text: text, body)
            case .image(let image): body(buffer(image.original), image.original.count)
            case .shape: break
            }
        }
        private static func visit(text: String, _ body: (LedgerBuffer?, Int) -> Void) {
            body(buffer(text), text.utf8.count)
        }
        private static func buffer(_ points: [DrawPoint]) -> LedgerBuffer? {
            guard points.count > 16 else { return nil }
            return points.withUnsafeBufferPointer { raw in
                raw.baseAddress.map { LedgerBuffer(address: UInt(bitPattern: $0), count: points.count) }
            }
        }
        private static func buffer(_ data: Data) -> LedgerBuffer? {
            guard data.count > 64 else { return nil }
            return data.withUnsafeBytes { raw in
                raw.baseAddress.map { LedgerBuffer(address: UInt(bitPattern: $0), count: data.count) }
            }
        }
        private static func buffer(_ text: String) -> LedgerBuffer? {
            guard text.utf8.count > 15 else { return nil }
            return text.utf8.withContiguousStorageIfAvailable { raw in
                raw.baseAddress.map { LedgerBuffer(address: UInt(bitPattern: $0), count: raw.count) }
            } ?? nil
        }
    }
}

#if DEBUG
enum HistoryLedgerProbe {
    static var stepVisits = 0
    static var objectVisits = 0
    static var footprintSets = 0
    static func reset() { stepVisits = 0; objectVisits = 0; footprintSets = 0 }
}
#endif
