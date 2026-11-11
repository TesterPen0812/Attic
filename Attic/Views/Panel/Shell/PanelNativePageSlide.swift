import AppKit
import QuartzCore
import SwiftUI

/// Owns the rendered page layers, while SwiftUI still owns each page's state.
/// Starting a slide here does not depend on the next SwiftUI view-graph pass.
@MainActor
final class PanelNativePageSlide {
    enum ChromeKind: Hashable { case topRow, bottomBar }

    private struct ChromeKey: Hashable {
        let page: PanelPage
        let kind: ChromeKind
    }

    private final class WeakHost {
        weak var view: PanelNativePageHostingView?
        init(_ view: PanelNativePageHostingView) { self.view = view }
    }

    private final class WeakChromeHost {
        weak var view: PanelNativeChromeHostingView?
        init(_ view: PanelNativeChromeHostingView) { self.view = view }
    }

    private struct Flight {
        let change: PanelPageSwitch
        let start: CFTimeInterval
        let width: CGFloat
        let generation: UInt64
        let coldDestination: Bool
    }

    private var hosts: [PanelPage: WeakHost] = [:]
    private var chromeHosts: [ChromeKey: WeakChromeHost] = [:]
    private var flight: Flight?
    /// A newly hosted page and a retained Tasks page whose pager is waking
    /// both need to paint before the outgoing page can uncover their area.
    private var waitingForPagePaint = false
    private var onSettled: (() -> Void)?
    private var generation: UInt64 = 0
    private var selected: PanelPage = .tasks

    /// Unit hosts and callers that have not presented the actual panel keep
    /// SwiftUI's original completion handling. No compositor flight exists.
    func hasDepartingHost(_ page: PanelPage) -> Bool {
        hosts[page]?.view?.layer != nil
    }

    func register(_ host: PanelNativePageHostingView, page: PanelPage, selected: PanelPage,
                  width: CGFloat) {
        hosts[page] = WeakHost(host)
        refresh(host, page: page, selected: selected, width: width)
    }

    /// `makeNSView` precedes SwiftUI's first hosted render. The page's
    /// onAppear is the earliest useful readiness signal; allow a display
    /// tick to commit its contents before the departing layer moves.
    func pageDidAppear(_ page: PanelPage) {
        guard waitingForPagePaint, flight?.coldDestination == true,
              page == flight?.change.to,
              hosts[page]?.view != nil else { return }
        let id = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.017) { [weak self] in
            guard let self, self.generation == id, self.waitingForPagePaint else { return }
            self.startFlight()
        }
    }

    /// Tasks keeps its hosting layer, but the native pager removes its rows
    /// while another page is selected. A retained host alone does not mean
    /// there are pixels ready to cover the moving Calendar/Notes page.
    func pageDidBecomeCurrent(_ page: PanelPage) {
        guard waitingForPagePaint, page == .tasks, page == flight?.change.to,
              flight?.coldDestination == false else { return }
        let id = generation
        // The Tasks pager rebuilds its visible rows after the page-current
        // notification. Allow it a few display frames before uncovering it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.generation == id, self.waitingForPagePaint else { return }
            self.startFlight()
        }
    }

    func unregister(_ host: PanelNativePageHostingView, page: PanelPage) {
        guard hosts[page]?.view === host else { return }
        hosts.removeValue(forKey: page)
        host.layer?.removeAnimation(forKey: Self.animationKey)
    }

    func registerChrome(_ host: PanelNativeChromeHostingView, page: PanelPage,
                        kind: ChromeKind, selected: PanelPage) {
        let key = ChromeKey(page: page, kind: kind)
        chromeHosts[key] = WeakChromeHost(host)
        refreshChrome(host, page: page, kind: kind, selected: selected)
    }

    func unregisterChrome(_ host: PanelNativeChromeHostingView, page: PanelPage, kind: ChromeKind) {
        let key = ChromeKey(page: page, kind: kind)
        guard chromeHosts[key]?.view === host else { return }
        chromeHosts.removeValue(forKey: key)
        host.layer?.removeAllAnimations()
    }

    func refreshChrome(_ host: PanelNativeChromeHostingView, page: PanelPage,
                       kind: ChromeKind, selected: PanelPage) {
        host.acceptsPageInput = page == self.selected
        guard let layer = host.layer else { return }
        let key = ChromeKey(page: page, kind: kind)
        if let flight, !waitingForPagePaint, flight.change.motion.travels,
           (page == flight.change.from || page == flight.change.to),
           CACurrentMediaTime() < flight.start + flight.change.motion.settleDuration {
            if layer.animation(forKey: Self.chromeOpacityKey) == nil {
                animateChrome(host, key: key, flight: flight)
            }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.chromeOpacityKey)
        layer.removeAnimation(forKey: Self.chromeTravelKey)
        layer.transform = CATransform3DIdentity
        layer.opacity = page == self.selected ? 1 : 0
        CATransaction.commit()
    }

    func refresh(_ host: PanelNativePageHostingView, page: PanelPage, selected: PanelPage,
                 width: CGFloat) {
        self.selected = flight?.change.to ?? selected
        host.acceptsPageInput = page == self.selected
        guard let layer = host.layer else { return }
        if waitingForPagePaint, let flight {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAnimation(forKey: Self.animationKey)
            if page == flight.change.from {
                // Still drawn and at rest until Notes/Calendar can cover it.
                layer.transform = CATransform3DIdentity
                layer.opacity = 1
            } else if page == flight.change.to {
                layer.transform = CATransform3DMakeTranslation(
                    flight.change.restingSide(of: page) * width, 0, 0)
                layer.opacity = 1
            } else {
                layer.opacity = 0
            }
            CATransaction.commit()
            return
        }
        if let flight, flight.change.motion.travels,
           (page == flight.change.from || page == flight.change.to),
           CACurrentMediaTime() < flight.start + flight.change.motion.settleDuration {
            // A cold destination may mount after the handler. Its animation
            // has the original start time, so it joins at the right position.
            if layer.animation(forKey: Self.animationKey) == nil {
                animate(host, page: page, flight: flight)
            }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.animationKey)
        layer.transform = CATransform3DMakeTranslation(page.side(from: selected) * width, 0, 0)
        layer.opacity = page == selected ? 1 : 0
        CATransaction.commit()
    }

    func begin(_ change: PanelPageSwitch, width: CGFloat, onSettled: @escaping () -> Void) {
        selected = change.to
        generation &+= 1
        self.onSettled = change.motion.travels ? onSettled : nil
        let id = generation
        let next = Flight(change: change, start: CACurrentMediaTime(), width: width,
                          generation: id, coldDestination: hosts[change.to]?.view == nil)
        flight = change.motion.travels ? next : nil
        waitingForPagePaint = change.motion.travels &&
            (hosts[change.to]?.view == nil || change.to == .tasks)
        // Native hit testing and VoiceOver ownership change in the handler,
        // even while SwiftUI has not yet reconciled its selected-page flags.
        for (page, weakHost) in hosts {
            weakHost.view?.acceptsPageInput = page == change.to
        }
        for (key, weakHost) in chromeHosts {
            weakHost.view?.acceptsPageInput = key.page == change.to
        }
        // The SwiftUI slide's top-row fades finish before its delayed first
        // moved frame. Give the native slide the same header at motion start,
        // including while a cold destination is preparing its first paint.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (key, weakHost) in chromeHosts where key.kind == .topRow {
            weakHost.view?.layer?.opacity = key.page == change.to ? 1 : 0
        }
        CATransaction.commit()
        if change.motion.travels {
            if waitingForPagePaint {
                for (page, weakHost) in hosts {
                    if let host = weakHost.view { refresh(host, page: page, selected: change.to, width: width) }
                }
            } else {
                startFlight()
            }
        } else {
            for (page, weakHost) in hosts {
                if let host = weakHost.view { refresh(host, page: page, selected: change.to, width: width) }
            }
        }
    }

    func cancel() {
        generation &+= 1
        waitingForPagePaint = false
        onSettled = nil
        flight = nil
        for (page, weakHost) in hosts {
            if let host = weakHost.view {
                refresh(host, page: page, selected: selected, width: host.bounds.width)
            }
        }
        for (key, weakHost) in chromeHosts {
            if let host = weakHost.view {
                refreshChrome(host, page: key.page, kind: key.kind, selected: selected)
            }
        }
    }

    private static let animationKey = "AtticNativePageSlide"
    private static let chromeOpacityKey = "AtticNativeChromeOpacity"
    private static let chromeTravelKey = "AtticNativeChromeCounterTravel"

    private func startFlight() {
        guard let previous = flight else { return }
        if waitingForPagePaint, let incoming = hosts[previous.change.to]?.view {
            // A hosted page can have an NSView before SwiftUI has filled its
            // backing layers. Finish its pending layout/display before the
            // departing page reveals any part of that destination.
            incoming.layoutSubtreeIfNeeded()
            incoming.displayIfNeeded()
            CATransaction.flush()
        }
        waitingForPagePaint = false
        let start = Flight(change: previous.change, start: CACurrentMediaTime(),
                           width: previous.width, generation: previous.generation,
                           coldDestination: previous.coldDestination)
        flight = start
        for page in [start.change.from, start.change.to] {
            if let host = hosts[page]?.view { animate(host, page: page, flight: start) }
            for kind in [ChromeKind.topRow, .bottomBar] {
                let key = ChromeKey(page: page, kind: kind)
                if let host = chromeHosts[key]?.view { animateChrome(host, key: key, flight: start) }
            }
        }
        // Compositor starts now even if SwiftUI has not published the next
        // body pass; every rendered host uses the same spring and start time.
        CATransaction.flush()
        #if DEBUG
        if ProcessInfo.processInfo.environment["ATTIC_PAGE_BENCH"] == "1" {
            PerformanceSignposts.noteInput("native-page-slide-enqueued hosts=\(hosts.values.compactMap(\.view).count)")
        }
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + start.change.motion.settleDuration) { [weak self] in
            guard let self, self.generation == start.generation else { return }
            self.flight = nil
            for (page, weakHost) in self.hosts {
                if let host = weakHost.view {
                    self.refresh(host, page: page, selected: start.change.to, width: start.width)
                }
            }
            for (key, weakHost) in self.chromeHosts {
                if let host = weakHost.view {
                    self.refreshChrome(host, page: key.page, kind: key.kind, selected: start.change.to)
                }
            }
            // The outgoing Tasks pager must keep drawing through the actual
            // composited flight. SwiftUI's animation completion can fire
            // earlier because the native layers own the page movement now.
            let callback = self.onSettled
            self.onSettled = nil
            callback?()
        }
    }

    private func animate(_ host: PanelNativePageHostingView, page: PanelPage, flight: Flight) {
        guard let layer = host.layer, let spring = flight.change.motion.spring else { return }
        let incoming = page == flight.change.to
        let side = flight.change.changeSide(for: page)
        let fromX = incoming ? side * flight.width : 0
        let toX = incoming ? 0 : side * flight.width
        // A new NSHostingView may have a presentation layer at identity
        // before its first transaction commits the offscreen resting offset.
        let from = (incoming && flight.coldDestination) ? fromX : (layer.presentation()?.transform.m41 ?? fromX)
        let to = CATransform3DMakeTranslation(toX, 0, 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.animationKey)
        layer.transform = to
        layer.opacity = 1
        // QuartzCore's perceptual-duration spring is close, but its sample
        // positions can differ from SwiftUI's spring. Sample SwiftUI's exact
        // oscillator and let Core Animation interpolate at 240 Hz; this
        // preserves the existing curve, distance and settling duration.
        let animation = Self.swiftUISpringAnimation(spring: spring,
                                                    from: Double(from), to: Double(toX))
        animation.beginTime = layer.convertTime(flight.start, from: nil)
        layer.add(animation, forKey: Self.animationKey)
        CATransaction.commit()
    }

    static func swiftUISpringAnimation(spring: AtticMotionSpring,
                                       from: Double, to: Double) -> CAKeyframeAnimation {
        let curve = Spring(duration: spring.response, bounce: spring.bounce)
        let duration = curve.settlingDuration
        let count = max(1, Int(ceil(duration * 240)))
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.duration = duration
        animation.calculationMode = .linear
        animation.values = (0...count).map { sample in
            NSNumber(value: curve.value(fromValue: from, toValue: to,
                                        initialVelocity: 0.0,
                                        time: duration * Double(sample) / Double(count)))
        }
        animation.keyTimes = (0...count).map { NSNumber(value: Double($0) / Double(count)) }
        return animation
    }

    private func animateChrome(_ host: PanelNativeChromeHostingView, key: ChromeKey, flight: Flight) {
        guard let layer = host.layer, let spring = flight.change.motion.spring else { return }
        let incoming = key.page == flight.change.to
        let side = flight.change.restingSide(of: key.page)
        let pageFrom = incoming ? side * flight.width : 0
        let pageTo = incoming ? 0 : side * flight.width
        // A retained page can begin from a presentation-layer offset if a
        // previous flight was interrupted. Counter the *actual* body spring
        // keyframes, including that first offset, to keep the header fixed.
        let bodyFrom = ((hosts[key.page]?.view?.layer?.animation(forKey: Self.animationKey)
            as? CAKeyframeAnimation)?.values?.first as? NSNumber)?.doubleValue ?? Double(pageFrom)
        let start = layer.convertTime(flight.start, from: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.chromeOpacityKey)
        layer.removeAnimation(forKey: Self.chromeTravelKey)
        if key.kind == .topRow {
            // The page's whole backing layer slides. Counteract its travel
            // on the header's own layer, keeping it fixed next to the pin.
            let inverse = Self.swiftUISpringAnimation(spring: spring,
                                                       from: -bodyFrom, to: Double(-pageTo))
            inverse.beginTime = start
            layer.transform = CATransform3DMakeTranslation(-pageTo, 0, 0)
            layer.add(inverse, forKey: Self.chromeTravelKey)
        } else {
            layer.transform = CATransform3DIdentity
        }
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.beginTime = start
        let startAlpha: Float = incoming ? 0 : 1
        let endAlpha: Float = incoming ? 1 : 0
        opacity.fromValue = startAlpha
        opacity.toValue = endAlpha
        opacity.duration = incoming ? PanelPageMotion.fadeIn : PanelPageMotion.fadeOut
        if key.kind == .topRow {
            // Keep the original 90/160 ms fade and easing, but position its
            // timeline before the body's first moved frame, as SwiftUI did.
            // CA joins the already-completed animation at the native trigger.
            opacity.beginTime = start - opacity.duration
            opacity.fillMode = .forwards
            opacity.isRemovedOnCompletion = false
        }
        opacity.timingFunction = CAMediaTimingFunction(name: incoming ? .easeOut : .easeIn)
        layer.opacity = endAlpha
        layer.add(opacity, forKey: Self.chromeOpacityKey)
        CATransaction.commit()
    }
}

private extension PanelPageSwitch {
    func changeSide(for page: PanelPage) -> CGFloat { restingSide(of: page) }
}

/// A page-sized native backing layer. A hidden page remains mounted and
/// renderable but cannot intercept pointer events or become a VoiceOver item.
final class PanelNativePageHostingView: NSHostingView<AnyView> {
    var acceptsPageInput = false

    // The wrapper is a compositor surface; SwiftUI's descendants are the
    // accessible controls. Exposing this full-page AX group itself makes the
    // panel's topmost-element hit test prefer it over real buttons.
    override func isAccessibilityElement() -> Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsPageInput ? super.hitTest(point) : nil
    }

    override func accessibilityChildren() -> [Any]? {
        acceptsPageInput ? super.accessibilityChildren() : []
    }
}

/// A page's native chrome has its own layer. It remains interactive only on
/// the current page, so overlap during the fade does not duplicate actions.
final class PanelNativeChromeHostingView: NSHostingView<AnyView> {
    var acceptsPageInput = false

    // Do not advertise the entire header/footer layer as a single AX target.
    override func isAccessibilityElement() -> Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsPageInput ? super.hitTest(point) : nil
    }

    override func accessibilityChildren() -> [Any]? {
        acceptsPageInput ? super.accessibilityChildren() : []
    }
}

struct PanelNativeChromeHost: NSViewRepresentable {
    let page: PanelPage
    let selected: PanelPage
    let kind: PanelNativePageSlide.ChromeKind
    let driver: PanelNativePageSlide
    let content: AnyView

    @Environment(\.self) private var environment

    func makeNSView(context: Context) -> PanelNativeChromeHostingView {
        let host = PanelNativeChromeHostingView(rootView: AnyView(content.environment(\.self, environment)))
        host.wantsLayer = true
        host.layer?.masksToBounds = false
        driver.registerChrome(host, page: page, kind: kind, selected: selected)
        return host
    }

    func updateNSView(_ host: PanelNativeChromeHostingView, context: Context) {
        host.rootView = AnyView(content.environment(\.self, environment))
        driver.refreshChrome(host, page: page, kind: kind, selected: selected)
    }

    static func dismantleNSView(_ host: PanelNativeChromeHostingView, coordinator: ()) {
        host.layer?.removeAllAnimations()
    }
}

struct PanelNativePageHost: NSViewRepresentable {
    let page: PanelPage
    let selected: PanelPage
    let width: CGFloat
    let driver: PanelNativePageSlide
    let content: AnyView

    func makeNSView(context: Context) -> PanelNativePageHostingView {
        let host = PanelNativePageHostingView(rootView: content)
        host.wantsLayer = true
        host.layer?.masksToBounds = false
        driver.register(host, page: page, selected: selected, width: width)
        return host
    }

    func updateNSView(_ host: PanelNativePageHostingView, context: Context) {
        host.rootView = content
        driver.refresh(host, page: page, selected: selected, width: width)
    }

    static func dismantleNSView(_ host: PanelNativePageHostingView, coordinator: ()) {
        // The registry stores weak references; a pending CA animation never
        // retains a page after SwiftUI has released its view.
        host.layer?.removeAnimation(forKey: "AtticNativePageSlide")
    }
}
