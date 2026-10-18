import AppKit
import XCTest
@testable import Attic

@objc(AtticInvisibleHostObserver)
final class InvisibleHostObserver: NSObject, XCTestObservation {
    private static let observer = InvisibleHostObserver()
    private var tokens: [NSObjectProtocol] = []
    private var violations: Set<String> = []
    private var currentTest: XCTestCase?

    @objc static func install() {
        XCTestObservationCenter.shared.addTestObserver(observer)
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
                    if let window = notification.object as? NSWindow, window.isKeyWindow {
                        self?.violations.insert("became key: \(type(of: window)) frame=\(window.frame)")
                    }
                }
            })
            tokens.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if NSApp.isActive { self?.violations.insert("application became active") }
                }
            })
            print("INVISIBLE_HOST_CANARY registered for whole bundle")
        }
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        onMain { currentTest = testCase }
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        onMain {
            guard TestPresentationPolicy.isInvisible else { return }
            for window in NSApp.windows where window.isKeyWindow {
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
                let window = NSApp.windows.first { $0.windowNumber == number }
                let name = window.map { String(describing: type(of: $0)) } ?? "WindowServer window #\(number)"
                violations.insert("on display: \(name) frame=\(frame)")
            }
            for violation in violations.sorted() {
                testCase.record(XCTIssue(type: .assertionFailure, compactDescription: "Invisible-host canary: \(violation)"))
            }
            print("INVISIBLE_HOST_CANARY \(testCase.name) violations=\(violations.count)")
            violations.removeAll()
            currentTest = nil
        }
    }
}
