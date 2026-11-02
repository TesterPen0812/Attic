#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
import QuartzCore
import SwiftUI
import UIKit

final class PhoneRenderingBenchmarks: XCTestCase {
    @MainActor func testTaskListScroll() async throws { try await benchmark(.taskScroll) }
    @MainActor func testTableNoteScroll() async throws { try await benchmark(.noteScroll) }
    @MainActor func testTableNoteTyping() async throws { try await benchmark(.noteTyping) }

    @MainActor private func benchmark(_ workload: Workload) async throws {
        #if targetEnvironment(simulator) && ATTIC_LOCAL_ONLY && !ATTIC_CLOUD_SYNC
        let env = ProcessInfo.processInfo.environment
        guard let requested = env["ATTIC_PHONE_BENCH_UDID"], !requested.isEmpty else {
            throw XCTSkip("Opt in with the dedicated synthetic iPhone Simulator UDID; see benchmark-protocol.md")
        }
        try require(UUID(uuidString: requested) != nil && requested.uppercased() == env["SIMULATOR_UDID"]?.uppercased(),
                    "Opt-in UDID does not match this Simulator")
        try require(UIDevice.current.userInterfaceIdiom == .phone && env["ATTIC_TESTING"] == "1",
                    "Requires the hosted iPhone test scheme")
        let scene = try await activeHostScene()
        let screen = scene.effectiveGeometry.coordinateSpace.bounds
        try require(screen.height > screen.width && screen.width >= Stage.size.width, "Requires a portrait iPhone viewport")
        for round in 1...4 {
            let order: [Engine] = round.isMultiple(of: 2) ? [.swiftUI, .uiKit] : [.uiKit, .swiftUI]
            for engine in order {
                let trial = try await runTrial(engine, workload, scene)
                let summary = trial.summary
                let record = Evidence(simulator: requested, model: env["SIMULATOR_MODEL_IDENTIFIER"],
                                      os: UIDevice.current.systemVersion, workload: workload.rawValue,
                                      engine: engine.rawValue, round: round, summary: summary, samples: trial)
                let data = try JSONEncoder().encode(record)
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "phone-bench-\(workload.rawValue)-\(engine.rawValue)-r\(round).json"
                attachment.lifetime = .keepAlways
                add(attachment)
                let line = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
                print("ATTIC_PHONE_BENCH \(workload.rawValue) \(engine.rawValue) round=\(round) \(line)")
            }
        }
        #else
        throw XCTSkip("Requires a local-only iOS Simulator test build")
        #endif
    }
}

private enum Engine: String { case uiKit = "UIKit", swiftUI = "SwiftUI" }
private enum Workload: String { case taskScroll, noteScroll, noteTyping }
#if targetEnvironment(simulator) && ATTIC_LOCAL_ONLY && !ATTIC_CLOUD_SYNC
private struct BenchFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
private func require(_ condition: Bool, _ reason: String) throws {
    if !condition { throw BenchFailure(reason) }
}

// Constant strides, no date/locale/random data and no Attic imports or stores.
private enum Corpus {
    static let taskHeight: CGFloat = 44, bodyHeight: CGFloat = 112, cellHeight: CGFloat = 26
    static let rows = 4, columns = 3, steps = 48, editSection = 24
    static var sectionHeight: CGFloat { bodyHeight + CGFloat(rows) * cellHeight }
    static let taskStarts = [0, 1000, 1940], noteStarts = [0, 24, 39]
    static let taskChecks = Set(taskStarts + taskStarts.map { $0 + steps })
    static let noteChecks = Set(noteStarts + noteStarts.map { $0 + steps / 8 })
    static let tasks = (0..<2000).map { i in
        "\(i.isMultiple(of: 3) ? "Done" : "Now") · Review sample task \(i)"
    }
    struct Section {
        let body: String, cells: [[String]]
        init(_ s: Int) {
            body = "Section \(s). Record the sample observations before the next review. "
                + "Compare the planned and observed values in the table below. Keep a note of each difference for the next pass."
            cells = (0..<rows).map { r in (0..<columns).map { c in "S\(s) R\(r) C\(c)" } }
        }
    }
    static let sections = (0..<48).map(Section.init)
    static func marker(_ index: Int) -> String { "phone-bench-witness-\(index)" }
}

@MainActor private final class Draft: NSObject, ObservableObject, UITextViewDelegate {
    @Published var text = Corpus.sections[Corpus.editSection].body
    func textViewDidChange(_ textView: UITextView) { text = textView.text }
}

@MainActor private func label(_ text: String, size: CGFloat, witness: Int? = nil) -> UILabel {
    let v = UILabel()
    v.font = .systemFont(ofSize: size)
    v.text = text
    v.lineBreakMode = .byTruncatingTail
    v.accessibilityIdentifier = witness.map(Corpus.marker)
    return v
}

// A few real content labels double as geometric witnesses in both renderers.
private struct WitnessText: UIViewRepresentable {
    let text: String, index: Int, size: CGFloat
    func makeUIView(context: Context) -> UILabel { label(text, size: size, witness: index) }
    func updateUIView(_ uiView: UILabel, context: Context) {
        uiView.text = text
        uiView.accessibilityIdentifier = Corpus.marker(index)
    }
}

private final class TaskCell: UICollectionViewCell {
    let title = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        title.frame = contentView.bounds.insetBy(dx: 8, dy: 0)
        title.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        title.font = .systemFont(ofSize: 16)
        contentView.addSubview(title)
    }
    required init?(coder: NSCoder) { fatalError("Test fixture is programmatic") }
}

private final class TaskCollection: UICollectionViewController {
    init(rowHeight: CGFloat) {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(rowHeight))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout(section: NSCollectionLayoutSection(group: group)))
    }
    required init?(coder: NSCoder) { fatalError("Test fixture is programmatic") }
    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.register(TaskCell.self, forCellWithReuseIdentifier: "task")
        collectionView.contentInsetAdjustmentBehavior = .never
    }
    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { Corpus.tasks.count }
    override func collectionView(_ collectionView: UICollectionView, cellForItemAt path: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "task", for: path) as! TaskCell
        cell.title.text = Corpus.tasks[path.item]
        cell.title.accessibilityIdentifier = Corpus.taskChecks.contains(path.item) ? Corpus.marker(path.item) : nil
        return cell
    }
}

private struct TaskStack: View {
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Corpus.tasks.indices, id: \.self) { i in
                    Group {
                        if Corpus.taskChecks.contains(i) { WitnessText(text: Corpus.tasks[i], index: i, size: 16) }
                        else { Text(verbatim: Corpus.tasks[i]).font(.system(size: 16)).lineLimit(1) }
                    }
                    .padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading).frame(height: Corpus.taskHeight)
                }
            }
        }
    }
}

@MainActor private func uiNote(_ draft: Draft) -> UIViewController {
    let controller = UIViewController(), scroll = UIScrollView(), blocks = UIStackView()
    controller.view = scroll
    scroll.contentInsetAdjustmentBehavior = .never
    blocks.axis = .vertical
    blocks.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(blocks)
    NSLayoutConstraint.activate([
        blocks.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
        blocks.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
        blocks.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
        blocks.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
        blocks.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
    ])
    for (i, section) in Corpus.sections.enumerated() {
        let body: UIView
        if i == Corpus.editSection {
            let editor = UITextView(usingTextLayoutManager: true)
            editor.font = .systemFont(ofSize: 14)
            editor.autocorrectionType = .no
            editor.autocapitalizationType = .none
            editor.text = draft.text
            editor.delegate = draft
            body = editor
        } else {
            let paragraph = label(section.body, size: 14)
            paragraph.numberOfLines = 0
            body = paragraph
        }
        blocks.addArrangedSubview(body)
        body.heightAnchor.constraint(equalToConstant: Corpus.bodyHeight).isActive = true
        for (r, values) in section.cells.enumerated() {
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fillEqually
            for (c, value) in values.enumerated() {
                let witness = r == 0 && c == 0 && Corpus.noteChecks.contains(i) ? i : nil
                let cell = label(value, size: 12, witness: witness)
                cell.backgroundColor = r.isMultiple(of: 2) ? .secondarySystemBackground : .systemBackground
                row.addArrangedSubview(cell)
            }
            blocks.addArrangedSubview(row)
            row.heightAnchor.constraint(equalToConstant: Corpus.cellHeight).isActive = true
        }
    }
    return controller
}

private struct EditableParagraph: View {
    @ObservedObject var draft: Draft
    var body: some View {
        TextEditor(text: $draft.text).font(.system(size: 14))
            .autocorrectionDisabled().textInputAutocapitalization(.never)
    }
}

private struct NoteStack: View {
    let draft: Draft
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Corpus.sections.indices, id: \.self) { i in
                    let section = Corpus.sections[i]
                    Group {
                        if i == Corpus.editSection { EditableParagraph(draft: draft) }
                        else { Text(verbatim: section.body).font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading) }
                    }.frame(height: Corpus.bodyHeight)
                    ForEach(0..<Corpus.rows, id: \.self) { r in
                        HStack(spacing: 0) {
                            ForEach(0..<Corpus.columns, id: \.self) { c in
                                let value = section.cells[r][c]
                                Group {
                                    if r == 0 && c == 0 && Corpus.noteChecks.contains(i) { WitnessText(text: value, index: i, size: 12) }
                                    else { Text(verbatim: value).font(.system(size: 12)).lineLimit(1) }
                                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            }
                        }.frame(height: Corpus.cellHeight)
                            .background(Color(uiColor: r.isMultiple(of: 2) ? .secondarySystemBackground : .systemBackground))
                    }
                }
            }
        }
    }
}

// Run the actuator directly in the display-link callback. Async suspension is only
// between phases; there is no polling sleep or per-frame dispatch to the main actor.
@MainActor private final class FrameClock: NSObject {
    private var link: CADisplayLink?
    private var timer: Timer?
    private var callback: ((Double) throws -> Bool)?
    private var continuation: CheckedContinuation<Void, Error>?
    private var phase = ""

    init(framesPerSecond: Float) {
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: framesPerSecond, maximum: framesPerSecond, preferred: framesPerSecond)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func until(_ phase: String, timeout: Double = 10, _ predicate: @escaping (Double) throws -> Bool) async throws {
        try require(continuation == nil && link != nil, "Overlapping or closed display-link phase")
        self.phase = phase
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.continuation = c
            self.callback = predicate
            let timer = Timer(timeInterval: timeout, target: self, selector: #selector(expired(_:)), userInfo: nil, repeats: false)
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    @objc private func tick(_ sender: CADisplayLink) {
        guard let callback else { return }
        do {
            if try callback(sender.timestamp) { finish(.success(())) }
        } catch { finish(.failure(error)) }
    }
    @objc private func expired(_ sender: Timer) { finish(.failure(BenchFailure("Timed out: \(phase)"))) }

    private func finish(_ result: Result<Void, Error>) {
        timer?.invalidate()
        timer = nil
        callback = nil
        let c = continuation
        continuation = nil
        c?.resume(with: result)
    }
    func close() {
        link?.invalidate()
        link = nil
        finish(.failure(BenchFailure("Clock closed during \(phase)")))
    }
}

private struct ActionSample: Encodable {
    let inputAt: Double, stateObservedAt: Double, refreshAt: Double, observedValue: Double
    var latencyMS: Double { (refreshAt - inputAt) * 1000 }
}
private struct Trace: Encodable {
    var intervalsMS: [Double] = [], actions: [ActionSample] = []
}
private struct Segment: Encodable {
    let anchor: Int, startWitness: String, endWitness: String, startY: Double, endY: Double, trace: Trace
}
private struct Trial: Encodable {
    let idleIntervalsMS: [Double], segments: [Segment]
    var summary: Summary {
        let baseline = median(idleIntervalsMS.sorted())
        let gaps = segments.flatMap { $0.trace.intervalsMS }.sorted()
        let latency = segments.flatMap { $0.trace.actions.map(\.latencyMS) }.sorted()
        return Summary(actions: latency.count, intervals: gaps.count, idleMedianMS: baseline,
                       intervalMedianMS: median(gaps), intervalP95MS: p95(gaps),
                       inputToRefreshMedianMS: median(latency), inputToRefreshP95MS: p95(latency),
                       estimatedMissedFrames: gaps.reduce(0) { $0 + max(0, Int(($1 / baseline).rounded()) - 1) })
    }
}
private struct Summary: Encodable {
    let actions: Int, intervals: Int, idleMedianMS: Double, intervalMedianMS: Double, intervalP95MS: Double
    let inputToRefreshMedianMS: Double, inputToRefreshP95MS: Double, estimatedMissedFrames: Int
}
private struct Evidence: Encodable {
    let simulator: String, model: String?, os: String, workload: String, engine: String, round: Int
    let summary: Summary, samples: Trial
}
// Callers have verified non-empty samples. p95 is the nearest-rank statistic.
private func median(_ sorted: [Double]) -> Double {
    (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
}
private func p95(_ sorted: [Double]) -> Double { sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1] }
private func gapMS(_ old: Double, _ new: Double) throws -> Double {
    try require(old.isFinite && new.isFinite && new > old, "Non-increasing display-link timestamps")
    return (new - old) * 1000
}

@MainActor private func idle(_ clock: FrameClock, count: Int = 24) async throws -> [Double] {
    var last: Double?, gaps: [Double] = []
    try await clock.until("idle cadence") { tick in
        if let last { gaps.append(try gapMS(last, tick)) }
        last = tick
        return gaps.count == count
    }
    return gaps
}

// At most one outstanding action. Do not use targetTimestamp (a prediction),
// or subtract a unit of guessed frame time from a slow callback. Hold the next
// input until the observed state survives a subsequent display-link boundary.
@MainActor private func drive(_ clock: FrameClock, _ phase: String, count: Int,
                              presentationMatches: @escaping (Int) -> Bool = { _ in true },
                              apply: @escaping (Int) throws -> Void,
                              observe: @escaping (Int) -> Double?) async throws -> Trace {
    var trace = Trace(), previous: Double?, start: Double?, ready: Double?
    try await clock.until(phase, timeout: 30) { tick in
        if let previous { trace.intervalsMS.append(try gapMS(previous, tick)) }
        previous = tick
        let index = trace.actions.count
        if let input = start {
            guard let value = observe(index) else { ready = nil; return false }
            if ready == nil { ready = CACurrentMediaTime() }
            guard let stamp = ready, tick >= stamp, presentationMatches(index) else { return false }
            trace.actions.append(ActionSample(inputAt: input, stateObservedAt: stamp, refreshAt: tick, observedValue: value))
            if trace.actions.count == count { return true }
        }
        let next = trace.actions.count
        start = CACurrentMediaTime()
        try apply(next)
        ready = observe(next) == nil ? nil : CACurrentMediaTime()
        return false
    }
    try require(trace.actions.count == count && !trace.intervalsMS.isEmpty, "Incomplete \(phase)")
    return trace
}

// Only traverse the test window's content. A changed SwiftUI implementation
// must fail explicitly rather than silently timing a nested or detached input.
@MainActor private func descendants<T: UIView>(_ root: UIView, of type: T.Type) -> [T] {
    var result: [T] = []
    var stack = [root]
    while let view = stack.popLast() {
        if let match = view as? T { result.append(match) }
        stack.append(contentsOf: view.subviews)
    }
    return result
}

@MainActor private func activeHostScene() async throws -> UIWindowScene {
    // XCTest can start while the host scene is still becoming active. This is
    // outside all measurements and never touches a host view or its data.
    for _ in 0..<100 {
        let active = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        try require(active.count <= 1, "Ambiguous host scene")
        if let scene = active.first, scene.keyWindow != nil { return scene }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw BenchFailure("No active hosted scene with a key window")
}

@MainActor private final class Stage {
    static let size = CGSize(width: 320, height: 320)
    let window: UIWindow
    let container = UIViewController()
    let content: UIViewController
    let previous: UIWindow

    init(_ content: UIViewController, scene: UIWindowScene) throws {
        guard let key = scene.keyWindow else { throw BenchFailure("Missing original key window") }
        previous = key
        self.content = content
        window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.windowLevel = UIWindow.Level(rawValue: key.windowLevel.rawValue + 1)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = container
        container.view.backgroundColor = .systemBackground
        container.addChild(content)
        let canvas = content.view!
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.clipsToBounds = true
        container.view.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.centerXAnchor.constraint(equalTo: container.view.centerXAnchor),
            canvas.topAnchor.constraint(equalTo: container.view.safeAreaLayoutGuide.topAnchor, constant: 4),
            canvas.widthAnchor.constraint(equalToConstant: Self.size.width),
            canvas.heightAnchor.constraint(equalToConstant: Self.size.height)
        ])
        content.didMove(toParent: container)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
    }
    func close() {
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
        window.windowScene = nil
        previous.makeKey()
        XCTAssertTrue(previous.isKeyWindow, "Original host window did not regain key status")
    }

    func scrollView(for workload: Workload) throws -> UIScrollView {
        let height = workload == .taskScroll ? CGFloat(Corpus.tasks.count) * Corpus.taskHeight
            : CGFloat(Corpus.sections.count) * Corpus.sectionHeight
        let candidates = descendants(content.view, of: UIScrollView.self).filter {
            !($0 is UITextView) && $0.window === window && $0.bounds.size == Self.size && abs($0.contentSize.height - height) <= 1
        }
        guard candidates.count == 1 else { throw BenchFailure("Expected one 320×320 scroller, height \(height); found \(candidates.count)") }
        return candidates[0]
    }

    func witness(_ index: Int, tasks: Bool, in scroll: UIScrollView) -> String? {
        let expected = tasks ? Corpus.tasks[index] : Corpus.sections[index].cells[0][0]
        let viewport = scroll.convert(scroll.bounds, to: window)
        for label in descendants(scroll, of: UILabel.self) where label.accessibilityIdentifier == Corpus.marker(index) && label.text == expected {
            let rect = label.convert(label.bounds, to: window)
            guard label.window === window, rect.width > 0, rect.height > 0,
                  viewport.contains(CGPoint(x: rect.midX, y: rect.midY)) else { continue }
            var node: UIView? = label
            while let v = node, !v.isHidden && v.alpha > 0.01 {
                if v === window { return expected }
                node = v.superview
            }
        }
        return nil
    }
}

@MainActor private func mounted(_ stage: Stage, _ clock: FrameClock, _ workload: Workload) async throws -> UIScrollView {
    var scroller: UIScrollView?, lastError = "fixture not attached"
    do {
        try await clock.until("mount \(workload.rawValue)") { _ in
            guard stage.window.isKeyWindow && stage.content.view.window === stage.window else { return false }
            do { scroller = try stage.scrollView(for: workload) }
            catch { lastError = error.localizedDescription; return false }
            return true
        }
    } catch { throw BenchFailure("\(error.localizedDescription): \(lastError)") }
    guard let scroller else { throw BenchFailure("Lost mounted scroll view") }
    return scroller
}

@MainActor private func checkpoint(_ index: Int, tasks: Bool, stage: Stage, scroll: UIScrollView, clock: FrameClock) async throws -> String {
    var text: String?
    try await clock.until("visible \(tasks ? "task" : "table") at \(index)") { _ in
        text = stage.witness(index, tasks: tasks, in: scroll)
        return text != nil
    }
    guard let text else { throw BenchFailure("Missing content witness \(index)") }
    return text
}

@MainActor private func scrollSegment(_ index: Int, tasks: Bool, warming: Bool, stage: Stage, scroll: UIScrollView, clock: FrameClock) async throws -> Segment {
    let block = tasks ? Corpus.taskHeight : Corpus.sectionHeight
    let stride = tasks ? block : block / 8
    let start = CGFloat(index) * block - scroll.adjustedContentInset.top
    scroll.setContentOffset(CGPoint(x: 0, y: start), animated: false)
    let first = try await checkpoint(index, tasks: tasks, stage: stage, scroll: scroll, clock: clock)
    let actualStart = scroll.contentOffset.y
    try require(abs(actualStart - start) <= 1, "Anchor offset differs at \(index)")
    let trace = try await drive(clock, "scroll from \(index)", count: warming ? 4 : Corpus.steps, presentationMatches: { step in
        guard let shownY = scroll.layer.presentation()?.bounds.minY else { return false }
        return abs(shownY - (start + CGFloat(step + 1) * stride)) <= 1
    }, apply: { step in
        scroll.setContentOffset(CGPoint(x: 0, y: start + CGFloat(step + 1) * stride), animated: false)
    }, observe: { step in
        let y = scroll.contentOffset.y
        return scroll.window === stage.window && abs(y - (start + CGFloat(step + 1) * stride)) <= 1 ? Double(y) : nil
    })
    let last = warming ? "" : try await checkpoint(index + (tasks ? Corpus.steps : Corpus.steps / 8), tasks: tasks, stage: stage, scroll: scroll, clock: clock)
    return Segment(anchor: index, startWitness: first, endWitness: last, startY: Double(actualStart), endY: Double(scroll.contentOffset.y), trace: trace)
}

private struct Edit {
    let insertion: String?, expected: String, caret: Int
}
private func edits(warming: Bool, from original: String) -> [Edit] {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
    var expected = original
    return (0..<(warming ? 8 : Corpus.steps)).map { i in
        let delete = warming ? i >= 4 : (i + 1).isMultiple(of: 8)
        let key = delete ? nil : String(alphabet[i % alphabet.count])
        if let key { expected += key } else { expected.removeLast() }
        return Edit(insertion: key, expected: expected, caret: expected.utf16.count)
    }
}

@MainActor private func caretIsVisible(_ editor: UITextView, in stage: Stage, scroll: UIScrollView) -> Bool {
    guard editor.window === stage.window, editor.isFirstResponder, let selection = editor.selectedTextRange else { return false }
    let rect = editor.caretRect(for: selection.end)
    guard rect.height > 0, rect.midX.isFinite, rect.midY.isFinite else { return false }
    let p = CGPoint(x: rect.midX, y: rect.midY)
    let root = stage.container.view!
    return editor.bounds.contains(p) && scroll.bounds.contains(editor.convert(p, to: scroll))
        && !root.keyboardLayoutGuide.layoutFrame.contains(editor.convert(p, to: root))
}

@MainActor private func focusEditor(_ stage: Stage, scroll: UIScrollView, clock: FrameClock, draft: Draft) async throws -> UITextView {
    let y = CGFloat(Corpus.editSection) * Corpus.sectionHeight - scroll.adjustedContentInset.top
    scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
    _ = try await checkpoint(Corpus.editSection, tasks: false, stage: stage, scroll: scroll, clock: clock)
    let candidates = descendants(scroll, of: UITextView.self).filter { $0.isEditable && $0.text == draft.text }
    guard candidates.count == 1 else { throw BenchFailure("Expected one editable paragraph backed by UITextView; found \(candidates.count)") }
    let editor = candidates[0]
    try require(editor.becomeFirstResponder(), "Editor declined first responder")
    editor.selectedRange = NSRange(location: draft.text.utf16.count, length: 0)
    _ = try await idle(clock, count: 30) // Keyboard transitions are outside timed input.
    scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
    try await clock.until("focused, unobscured note caret") { _ in caretIsVisible(editor, in: stage, scroll: scroll) }
    return editor
}

@MainActor private func typeSegment(_ editor: UITextView, warming: Bool, draft: Draft, stage: Stage,
                                    scroll: UIScrollView, clock: FrameClock) async throws -> Segment {
    let index = Corpus.editSection, original = Corpus.sections[Corpus.editSection].body
    try require(editor.text == original && draft.text == original && editor.selectedRange == NSRange(location: original.utf16.count, length: 0),
                "Unexpected paragraph or insertion point before edits")
    let sequence = edits(warming: warming, from: original)
    let first = try await checkpoint(index, tasks: false, stage: stage, scroll: scroll, clock: clock)
    let startY = scroll.contentOffset.y
    let trace = try await drive(clock, "typing in section \(index)", count: sequence.count, apply: { step in
        if let key = sequence[step].insertion { editor.insertText(key) } else { editor.deleteBackward() }
    }, observe: { step in
        let edit = sequence[step]
        guard editor.text == edit.expected, draft.text == edit.expected,
              editor.selectedRange == NSRange(location: edit.caret, length: 0), caretIsVisible(editor, in: stage, scroll: scroll)
        else { return nil }
        return Double(editor.selectedRange.location)
    })
    let last = try await checkpoint(index, tasks: false, stage: stage, scroll: scroll, clock: clock)
    try require(editor.text == sequence.last?.expected && draft.text == editor.text, "Final text disagrees with the edit script")
    return Segment(anchor: index, startWitness: first, endWitness: last, startY: Double(startY), endY: Double(scroll.contentOffset.y), trace: trace)
}

@MainActor private func hosted<V: View>(_ view: V) -> UIViewController {
    let controller = UIHostingController(rootView: view)
    controller.safeAreaRegions = [] // The parent already locates the fixed viewport inside the safe area.
    return controller
}

@MainActor private func runTrial(_ engine: Engine, _ workload: Workload, _ scene: UIWindowScene) async throws -> Trial {
    let draft = Draft()
    let tasks = workload == .taskScroll
    let content: UIViewController
    switch (engine, tasks) {
    case (.uiKit, true): content = TaskCollection(rowHeight: Corpus.taskHeight)
    case (.swiftUI, true): content = hosted(TaskStack())
    case (.uiKit, false): content = uiNote(draft)
    case (.swiftUI, false): content = hosted(NoteStack(draft: draft))
    }
    let stage = try Stage(content, scene: scene)
    defer { stage.close() }
    let clock = FrameClock(framesPerSecond: 60)
    defer { clock.close() }
    let scroll = try await mounted(stage, clock, workload)
    var segments: [Segment] = []
    let baseline: [Double]
    if workload == .noteTyping {
        let editor = try await focusEditor(stage, scroll: scroll, clock: clock, draft: draft)
        if engine == .uiKit { try require(editor.textLayoutManager != nil, "UIKit fixture requires TextKit 2") }
        _ = try await typeSegment(editor, warming: true, draft: draft, stage: stage, scroll: scroll, clock: clock)
        baseline = try await calibratedIdle(clock)
        segments.append(try await typeSegment(editor, warming: false, draft: draft, stage: stage, scroll: scroll, clock: clock))
    } else {
        _ = try await scrollSegment(0, tasks: tasks, warming: true, stage: stage, scroll: scroll, clock: clock)
        baseline = try await calibratedIdle(clock)
        for anchor in tasks ? Corpus.taskStarts : Corpus.noteStarts {
            segments.append(try await scrollSegment(anchor, tasks: tasks, warming: false, stage: stage, scroll: scroll, clock: clock))
        }
    }
    try require(segments.count == (workload == .noteTyping ? 1 : 3) && stage.window.isKeyWindow && scene.activationState == .foregroundActive,
                "Incomplete trial or host no longer foreground")
    return Trial(idleIntervalsMS: baseline, segments: segments)
}

@MainActor private func calibratedIdle(_ clock: FrameClock) async throws -> [Double] {
    let gaps = try await idle(clock)
    let typical = median(gaps.sorted())
    try require(abs(typical - 1000.0 / 60.0) <= 1.7, "Requested 60 Hz but observed idle median \(typical) ms")
    return gaps
}
#endif
#endif
