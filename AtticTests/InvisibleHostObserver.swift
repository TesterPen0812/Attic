import AppKit
import XCTest
@testable import Attic

@objc(AtticInvisibleHostObserver)
final class InvisibleHostObserver: NSObject, XCTestObservation {
    private static let observer = InvisibleHostObserver()
    private var tokens: [NSObjectProtocol] = []
    private var violations: Set<String> = []

    @objc static func install() -> NSNumber {
        XCTestObservationCenter.shared.addTestObserver(observer)
        return NSNumber(value: TestPresentationPolicy.isInvisible)
    }

    @objc(inspect:) static func inspect(_ testCase: XCTestCase) {
        observer.checkAfterTeardown(testCase)
    }

    private func onMain(_ body: @MainActor () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated { body() } }
        else { DispatchQueue.main.sync { MainActor.assumeIsolated { body() } } }
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        onMain {
            guard TestPresentationPolicy.isInvisible else { return }
            let center = NotificationCenter.default
            tokens.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    if let window = notification.object as? NSWindow, window === NSApp.keyWindow {
                        self?.violations.insert("became key: \(type(of: window)) frame=\(window.frame)")
                    }
                }
            })
            tokens.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if NSApp.isActive { self?.violations.insert("application became active") }
                }
            })
            tokens.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                self?.violations.insert("native NSMenu began tracking in the invisible host")
            })
            print("INVISIBLE_HOST_CANARY registered for whole bundle")
        }
    }

    private func checkAfterTeardown(_ testCase: XCTestCase) {
        onMain {
            guard TestPresentationPolicy.isInvisible else { return }
            // Never-ordered rendering fixtures may override isKeyWindow
            // to draw a caret; NSApp.keyWindow is AppKit's actual key owner.
            if let window = NSApp.keyWindow {
                violations.insert("key window: \(type(of: window)) frame=\(window.frame)")
            }
            if NSApp.isActive { violations.insert("application is active") }
            // CG and NSScreen use opposite Y axes. Query CG displays as well
            // as CG windows so mixed/negative display origins stay correct.
            var count: UInt32 = 0
            CGGetActiveDisplayList(0, nil, &count)
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            CGGetActiveDisplayList(count, &displays, &count)
            let frames = displays.prefix(Int(count)).map { CGDisplayBounds($0) }
            let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
            for info in windows where (info[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier {
                guard info[kCGWindowIsOnscreen as String] as? Bool == true,
                      let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                      let frame = CGRect(dictionaryRepresentation: bounds),
                      frames.contains(where: { $0.intersects(frame) }) else { continue }
                let number = info[kCGWindowNumber as String] as? Int ?? -1
                let window = NSApp.window(withWindowNumber: number)
                let name = window.map { String(describing: type(of: $0)) } ?? "WindowServer window #\(number)"
                violations.insert("on display: \(name) #\(number) frame=\(frame) appKitFrame=\(String(describing: window?.frame))")
            }
            for violation in violations.sorted() {
                testCase.record(XCTIssue(type: .assertionFailure, compactDescription: "Invisible-host canary: \(violation)"))
            }
            print("INVISIBLE_HOST_CANARY \(testCase.name) violations=\(violations.count)")
            violations.removeAll()
        }
    }
}
