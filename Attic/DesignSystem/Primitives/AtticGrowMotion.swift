import AppKit
import SwiftUI

// MARK: - Grow from what's there (Accepted 2026-11-13, "Motion into notes")

/// Where a page grows from: the row or card that opened it, in its
/// window's coordinates (AppKit's, bottom-left origin), with what it showed
/// so the shell can start out looking like it.
struct AtticGrowOrigin: Equatable {
    /// The highlight's rectangle in window coordinates.
    var frame: CGRect
    var cornerRadius: CGFloat
    /// The row's title, carried for the first part of the growth ("" for
    /// none, e.g. a click with no row under it).
    var title: String = ""
    var titleStyle: AtticTextStyle = .rowTitle
    /// The title's leading edge and the height it is centred in, from the
    /// rectangle's top-left (a card's title sits at its top).
    var titleInset: CGFloat = AtticLayout.textX - AtticLayout.rowHighlightInset
    var titleBand: CGFloat? = nil
    /// The window the frame is in (0: whichever window asks).
    var windowNumber: Int = 0

    /// A row-high band across the window at the click's height: the origin
    /// of a page opened by a click on something that has no row frame to
    /// give (a Calendar card's row, a link in the chat). Nil when the
    /// current event is not a click.
    @MainActor
    static func atCurrentClick() -> AtticGrowOrigin? {
        guard let event = NSApp.currentEvent, let window = event.window,
              [.leftMouseDown, .leftMouseUp, .otherMouseUp].contains(event.type),
              let content = window.contentView else { return nil }
        var origin = band(at: event.locationInWindow, contentWidth: content.bounds.width)
        origin?.windowNumber = window.windowNumber
        return origin
    }

    /// A Tasks row's slot (window coordinates): its highlight, inset as
    /// the row draws it, with the title where the row has it.
    static func taskRow(_ slot: CGRect, title: String, windowNumber: Int) -> AtticGrowOrigin {
        // A row with a second line (tags, subtasks) is taller; its title
        // stays in the first 28 pt.
        let frame = slot.insetBy(dx: AtticLayout.rowHighlightInset,
                                 dy: max(0, (AtticLayout.rowPitch - AtticLayout.rowHighlightHeight) / 2))
        return AtticGrowOrigin(frame: frame, cornerRadius: AtticRadius.highlight, title: title,
                               titleBand: AtticLayout.rowHighlightHeight, windowNumber: windowNumber)
    }

    /// The band `atCurrentClick` makes (testable without an event).
    static func band(at point: CGPoint, contentWidth: CGFloat) -> AtticGrowOrigin? {
        let inset = AtticLayout.rowHighlightInset + AtticLayout.contentFromChrome
        let height = AtticLayout.rowHighlightHeight
        guard contentWidth > 2 * inset else { return nil }
        return AtticGrowOrigin(frame: CGRect(x: inset, y: point.y - height / 2,
                                             width: contentWidth - 2 * inset, height: height),
                               cornerRadius: AtticRadius.highlight)
    }
}

/// One page growing out of its row or card and shrinking back into it.
/// Pure state (unit-tested); the host animates `shellTarget` and the two
/// pages' visibility with the animations it names.
///
/// - grow: the row's highlight grows into the page on the `expand` spring
///   (L, the feel's spatial spring) and dissolves as it gets there; its
///   title fades in the first 40 %. The rest of the origin clears at the
///   click; the page fades in (M/E) as the shell nears full size. Back
///   runs it in reverse from wherever it is.
/// - fade: no origin to grow from, or Reduced with Fade: the 0.12 s fade.
/// - instant: Reduced with Instant: today's page change, at once.
struct AtticGrowState: Equatable {
    enum Phase: Equatable { case idle, opening, open, closing }
    enum Style: Equatable { case grow, fade, instant }

    private(set) var phase: Phase = .idle
    private(set) var style: Style = .instant
    private(set) var origin: AtticGrowOrigin?
    /// Bumped by every change of direction, so a finished animation only
    /// settles the run that started it (a second click mid-motion wins).
    private(set) var generation = 0
    /// The page being opened is built and on screen: the shell, holding
    /// at full size over the build, gives way to it.
    private(set) var arrived = false

    static func style(reduceMotion: Bool, reducedStyle: AtticReducedMotionStyle, hasOrigin: Bool) -> Style {
        #if DEBUG
        if AtticGrowTrace.disabled { return .instant }
        #endif
        if reduceMotion { return reducedStyle == .fade ? .fade : .instant }
        return hasOrigin ? .grow : .fade
    }

    /// Opens (or, closing, turns back towards the page from where it is).
    mutating func open(from origin: AtticGrowOrigin?, reduceMotion: Bool, reducedStyle: AtticReducedMotionStyle) {
        if let origin { self.origin = origin } else if phase == .idle { self.origin = nil }
        style = Self.style(reduceMotion: reduceMotion, reducedStyle: reducedStyle, hasOrigin: self.origin != nil)
        phase = style == .instant ? .open : .opening
        arrived = false
        generation &+= 1
    }

    /// Back: shrinks into `origin` (the row as it is now; the one it opened
    /// from when the row can't be found). Nothing open: nothing to do.
    mutating func close(to origin: AtticGrowOrigin?, reduceMotion: Bool, reducedStyle: AtticReducedMotionStyle) {
        guard phase == .opening || phase == .open else { return }
        if let origin { self.origin = origin }
        style = Self.style(reduceMotion: reduceMotion, reducedStyle: reducedStyle, hasOrigin: self.origin != nil)
        phase = style == .instant ? .idle : .closing
        generation &+= 1
    }

    /// The page refused to let go (a composition, a save not yet durable):
    /// it grows back from wherever the shrink had got to.
    mutating func refuseClose() {
        guard phase == .closing else { return }
        phase = .opening
        arrived = true
        generation &+= 1
    }

    /// The page is there (built and showing): an opening shell gives way.
    /// Turning round (a refused Back) the page was there all along.
    mutating func destinationArrived() {
        guard phase == .opening, !arrived else { return }
        arrived = true
    }

    /// The run started at `generation` has finished moving.
    mutating func finish(_ generation: Int) {
        guard generation == self.generation else { return }
        switch phase {
        case .opening: phase = .open
        case .closing: phase = .idle; origin = nil
        case .idle, .open: break
        }
    }

    /// The route went away by other means (a purge, Open in Window): no
    /// motion, nothing left on screen.
    mutating func reset() {
        guard phase != .idle else { return }
        phase = .idle
        origin = nil
        generation &+= 1
    }

    /// 1: the shell fills the page; 0: it is the row.
    var shellTarget: CGFloat { phase == .opening || phase == .open ? 1 : 0 }
    /// The shell is drawn only while it moves.
    var drawsShell: Bool { style == .grow && (phase == .opening || phase == .closing) && origin != nil }
    /// The page shows from the click on (and stops showing at Back's).
    var showsDestination: Bool { phase == .opening || phase == .open }
    /// The origin shows until the click and again from Back's.
    var showsOrigin: Bool { phase == .idle || phase == .closing }
    var isMoving: Bool { phase == .opening || phase == .closing }

    /// The shell's spring: `expand` (L, the feel's spatial spring).
    var shellAnimation: Animation? {
        style == .grow ? AtticMotionPreset.expand.animation(reduceMotion: false) : nil
    }

    /// The page's fade: in, M/E once the shell is under way (fade: F/E at
    /// once); out, the exit at once. Instant: nil.
    func destinationAnimation(showing: Bool) -> Animation? {
        switch style {
        case .instant: nil
        case .fade: showing ? AtticMotionScale.reducedFade : AtticMotionScale.exit
        case .grow: showing ? AtticMotionScale.easeOut(AtticMotionScale.standard).delay(Self.destinationDelay)
                            : AtticMotionScale.exit
        }
    }

    /// The origin's fade: back, M/E a little after the shrink starts (fade:
    /// F/E); out, the exit (fade) or at once (grow: the row has become the
    /// shell, and the list must not hang half-faded while the page is built
    /// on the main thread). Instant: nil.
    func originAnimation(showing: Bool) -> Animation? {
        switch style {
        case .instant: nil
        case .fade: showing ? AtticMotionScale.reducedFade : AtticMotionScale.exit
        case .grow: showing ? AtticMotionScale.easeOut(AtticMotionScale.standard).delay(AtticMotionScale.gapCloseDelay) : nil
        }
    }

    /// The page starts to show this long after the click, while the shell
    /// is a third of the way there.
    /// The shortest grow before the shell gives way to its page.
    static let minimumGrow: CFTimeInterval = 0.14
    static let destinationDelay: Double = 0.08
    /// The carried title is gone by this much of the growth.
    static let titleFadeEnd: CGFloat = 0.4
}

// MARK: - The shell (Core Animation)

/// One run of the shell: where it starts and ends, and its fades. Starting
/// mid-run (a second click, Escape mid-motion) it starts from where the
/// shell is now, so it turns round without a jump.
struct AtticGrowPlan: Equatable {
    struct Pose: Equatable {
        var frame: CGRect
        var radius: CGFloat
        var opacity: Float
        var titleOpacity: Float
    }

    var from: Pose
    var to: Pose
    /// The title's fade, as fractions of the run (opening: gone by 40 %;
    /// closing: back over the last 40 %).
    var titleStart: Double
    var titleEnd: Double

    /// At full size the shell holds this much of the row's fill over the
    /// page being built, and gives way when the page is there (no blank
    /// frames while the main thread builds it).
    static let holdOpacity: Float = 0.6

    static func make(_ state: AtticGrowState, origin: CGRect, page: CGRect, current: Pose?) -> AtticGrowPlan? {
        guard state.drawsShell else { return nil }
        // The title rides out only: on the way back the row's own title is
        // already fading in under the shell, and two would double.
        let row = Pose(frame: origin, radius: state.origin?.cornerRadius ?? AtticRadius.highlight, opacity: 1,
                       titleOpacity: state.phase == .opening ? 1 : 0)
        let full = Pose(frame: page, radius: AtticRadius.card, opacity: holdOpacity, titleOpacity: 0)
        let fade = Double(AtticGrowState.titleFadeEnd)
        switch state.phase {
        case .opening: return AtticGrowPlan(from: current ?? row, to: full, titleStart: 0, titleEnd: fade)
        case .closing: return AtticGrowPlan(from: current ?? full, to: row, titleStart: 1 - fade, titleEnd: 1)
        case .idle, .open: return nil
        }
    }
}

/// The shell drawn by Core Animation over the pages: a rounded rectangle in
/// the selected row's fill, with the row's title for the first part. It
/// runs on the render server, so it keeps moving while the page it opens
/// is being built on the main thread (that build is why the click used to
/// show nothing for ~140 ms). Click-through and hidden from accessibility.
/// It also converts the origin's window rectangle into the page's space.
struct AtticGrowLayer: NSViewRepresentable {
    let state: AtticGrowState
    let onFinish: (Int) -> Void

    @Environment(\.atticDesign) private var design

    func makeNSView(context: Context) -> ShellView { ShellView() }

    func updateNSView(_ view: ShellView, context: Context) {
        view.onFinish = onFinish
        view.apply(state, design: design)
    }

    @MainActor
    final class ShellView: NSView {
        var onFinish: ((Int) -> Void)?
        private let shell = CALayer()
        private let title = CATextLayer()
        private var runGeneration: Int?
        private var fadedGeneration: Int?
        private var runStartedAt: CFTimeInterval = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            shell.cornerCurve = .continuous
            shell.masksToBounds = true
            shell.isHidden = true
            shell.anchorPoint = .zero
            title.anchorPoint = .zero
            title.truncationMode = .end
            title.isWrapped = false
            shell.addSublayer(title)
            layer?.addSublayer(shell)
            setAccessibilityElement(false)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        private var currentPose: AtticGrowPlan.Pose? {
            guard runGeneration != nil, !shell.isHidden else { return nil }
            let now = shell.presentation() ?? shell
            return .init(frame: CGRect(origin: now.position, size: now.bounds.size), radius: now.cornerRadius,
                         opacity: now.opacity, titleOpacity: (title.presentation() ?? title).opacity)
        }

        func apply(_ state: AtticGrowState, design: AtticDesignContext) {
            guard state.drawsShell, let origin = state.origin, let window,
                  origin.windowNumber == 0 || origin.windowNumber == window.windowNumber else {
                if !state.isMoving || !state.drawsShell { hideShell() }
                return
            }
            if runGeneration != state.generation {
                let local = convert(origin.frame, from: nil)
                guard let plan = AtticGrowPlan.make(state, origin: local, page: bounds, current: currentPose) else { return }
                runGeneration = state.generation
                runStartedAt = CACurrentMediaTime()
                fadedGeneration = nil
                run(plan, origin: origin, generation: state.generation, completes: state.phase == .closing, design: design)
            }
            if state.phase == .opening, state.arrived, fadedGeneration != state.generation {
                fadedGeneration = state.generation
                giveWay(state.generation)
            }
        }

        /// The page is there: the shell fades into it (M/E), and the run
        /// is over when it has.
        private func giveWay(_ generation: Int) {
            #if DEBUG
            AtticGrowTrace.mark("giveway", style: .grow)
            #endif
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let from = (shell.presentation() ?? shell).opacity
            shell.removeAnimation(forKey: "opacity")
            shell.opacity = 0
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.runGeneration == generation else { return }
                    self.onFinish?(generation)
                }
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = 0
            fade.duration = AtticMotionScale.standard
            // A page that is there at once (a note) still lets the shell
            // grow most of the way first, so there is no empty frame.
            let wait = max(0, runStartedAt + AtticGrowState.minimumGrow - CACurrentMediaTime())
            if wait > 0 {
                fade.beginTime = CACurrentMediaTime() + wait
                fade.fillMode = .backwards
            }
            fade.timingFunction = AtticMotionScale.easeOutTimingFunction
            shell.add(fade, forKey: "opacity")
            CATransaction.commit()
        }

        private func hideShell() {
            #if DEBUG
            if runGeneration != nil { AtticGrowTrace.mark("hide", style: .grow) }
            #endif
            runGeneration = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shell.removeAllAnimations()
            title.removeAllAnimations()
            shell.isHidden = true
            CATransaction.commit()
        }

        private func run(_ plan: AtticGrowPlan, origin: AtticGrowOrigin, generation: Int, completes: Bool,
                         design: AtticDesignContext) {
            let tokens = design.tokens
            let scale = window?.backingScaleFactor ?? 2
            let spring = AtticMotionPreset.expand.spring(in: .current)
            let animation = CASpringAnimation(perceptualDuration: spring.response, bounce: spring.bounce)
            let duration = animation.settlingDuration
            let font = origin.titleStyle.nsFont
            let band = origin.titleBand ?? plan.from.frame.height

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shell.removeAllAnimations()
            title.removeAllAnimations()
            shell.isHidden = false
            shell.backgroundColor = tokens.selected.nsColor.cgColor
            shell.contentsScale = scale
            title.contentsScale = scale
            title.string = NSAttributedString(string: origin.title, attributes: [
                .font: font, .foregroundColor: tokens.ink(.heading).nsColor])
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            let rowWidth = origin.frame.width
            title.frame = CGRect(x: origin.titleInset, y: max(0, (band - lineHeight) / 2),
                                 width: max(0, rowWidth - origin.titleInset - AtticSpacing.s8), height: lineHeight)
            // The model holds the end; the animations run from the start.
            shell.position = plan.to.frame.origin
            shell.bounds = CGRect(origin: .zero, size: plan.to.frame.size)
            shell.cornerRadius = plan.to.radius
            shell.opacity = plan.to.opacity
            title.opacity = plan.to.titleOpacity
            if completes {
                // Done when the spring's main motion is (its tail is
                // sub-pixel): the row under it is back by then.
                DispatchQueue.main.asyncAfter(deadline: .now() + spring.response + AtticMotionScale.gapCloseDelay) { [weak self] in
                    guard let self, self.runGeneration == generation else { return }
                    self.onFinish?(generation)
                }
            }
            func springed(_ key: String, _ from: Any, _ to: Any) {
                let move = CASpringAnimation(perceptualDuration: spring.response, bounce: spring.bounce)
                move.keyPath = key
                move.fromValue = from
                move.toValue = to
                move.duration = duration
                shell.add(move, forKey: key)
            }
            springed("position", NSValue(point: plan.from.frame.origin), NSValue(point: plan.to.frame.origin))
            springed("bounds.size", NSValue(size: plan.from.frame.size), NSValue(size: plan.to.frame.size))
            springed("cornerRadius", plan.from.radius, plan.to.radius)
            // The fill dissolves along the way (E, so it never overshoots).
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = plan.from.opacity
            fade.toValue = plan.to.opacity
            fade.duration = spring.response
            fade.timingFunction = AtticMotionScale.easeOutTimingFunction
            shell.add(fade, forKey: "opacity")
            // Keyframes, not a begin time: the run starts when it is
            // committed, which a busy main thread can put off.
            let words = CAKeyframeAnimation(keyPath: "opacity")
            words.values = [plan.from.titleOpacity, plan.from.titleOpacity, plan.to.titleOpacity, plan.to.titleOpacity]
            words.keyTimes = [0, NSNumber(value: plan.titleStart), NSNumber(value: plan.titleEnd), 1]
            words.duration = spring.response
            title.add(words, forKey: "opacity")
            CATransaction.commit()
            // To the render server now: the page's build may hold the
            // main thread's next frame back, but not this.
            CATransaction.flush()
            #if DEBUG
            AtticGrowTrace.mark("shell", style: .grow)
            #endif
        }
    }
}

/// Hands a run's end back to its state (the shell's completion).
extension Binding where Value == AtticGrowState {
    func finish(_ generation: Int) { wrappedValue.finish(generation) }
}

/// Settles a run that has no shell (fade, instant) once its fade is over.
@MainActor
enum AtticGrowDriver {
    /// A shell run settles on its own completion; this is its backstop (a
    /// shell that couldn't be drawn, a window gone mid-run), which the
    /// generation makes harmless when the run did finish.
    static func settleWithoutShell(_ state: Binding<AtticGrowState>) {
        let generation = state.wrappedValue.generation
        let settle = state.wrappedValue.drawsShell ? shellBackstop
            : state.wrappedValue.style == .instant ? 0 : AtticMotionScale.fast
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { state.wrappedValue.finish(generation) }
    }

    static let shellBackstop: Double = 2
    /// A frame and a bit at 60 Hz: long enough for the run loop to commit
    /// the click's frame (the list cleared, the shell at its row).
    static let firstFrameWait: UInt64 = 20_000_000

    /// The main thread hands the click's first frame to the render server
    /// before the page it opens is built (a heavy build would otherwise
    /// hold that frame back).
    static func yieldFirstFrame(_ style: AtticGrowState.Style) async {
        guard style != .instant else { return }
        try? await Task.sleep(nanoseconds: firstFrameWait)
        #if DEBUG
        AtticGrowTrace.mark("yielded", style: style)
        #endif
    }
}

#if DEBUG
/// Capture seam (`ATTIC_UI_TEST_GROW_LOG=<path>`, preview identity only):
/// each click's host time (`CACurrentMediaTime`, the clock ScreenCaptureKit
/// stamps frames with), for click → first moving frame. And
/// `ATTIC_UI_TEST_GROW_OFF=1`: today's instant route, for the "before".
@MainActor
enum AtticGrowTrace {
    nonisolated static let disabled = ProcessInfo.processInfo.environment["ATTIC_UI_TEST_GROW_OFF"] == "1"
        && ProcessInfo.processInfo.environment["ATTIC_UI_TESTING"] == "1"
    /// A file name in the app's (sandboxed) temporary folder.
    nonisolated private static let path = ProcessInfo.processInfo.environment["ATTIC_UI_TESTING"] == "1"
        ? ProcessInfo.processInfo.environment["ATTIC_UI_TEST_GROW_LOG"].map {
            (NSTemporaryDirectory() as NSString).appendingPathComponent(($0 as NSString).lastPathComponent)
        } : nil

    static func mark(_ event: String, style: AtticGrowState.Style) {
        guard let path else { return }
        let line = String(format: "%@ %@ %.4f\n", event, "\(style)", CACurrentMediaTime())
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: false, encoding: .utf8)
        }
    }
}
#endif
