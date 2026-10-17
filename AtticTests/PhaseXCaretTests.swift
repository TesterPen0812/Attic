import AppKit
import XCTest
@testable import Attic

/// The caret's marquee-visibility observer (what remains of F-03's fitter
/// after O18-03, owner 2026-10-17: the caret is AppKit's own). Its geometry
/// is tested against real indicators in `RoundF3CaretTests`.
@MainActor
final class PhaseXCaretTests: XCTestCase {
    private var windows: [NSWindow] = []
    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    func testSmoothRetiredCaretObserversAreUnregistered() {
        let notifications = CountingCaretNotifications()
        let view = NSTextView(usingTextLayoutManager: true)
        var fitter: NoteCaretVisibility? = NoteCaretVisibility(textView: view, notifications: notifications)
        for _ in 0..<50 {
            weak var released: NSView?
            autoreleasepool {
                let indicator = NSTextInsertionIndicator(frame: .zero)
                released = indicator
                view.addSubview(indicator)
                fitter?.refresh()
                indicator.removeFromSuperview()
            }
            XCTAssertNil(released, "the fixture must retire the indicator")
            fitter?.refresh()
        }
        XCTAssertEqual(notifications.added, 50)
        XCTAssertEqual(notifications.removed, 50, "dead indicators must not leave block observers behind")
        fitter = nil
        XCTAssertEqual(notifications.removed, notifications.added, "teardown must balance every registration")
    }

}


/// Independent registration counts: a weak indicator alone cannot prove
/// NotificationCenter released its block observer.
private final class CountingCaretNotifications: NotificationCenter, @unchecked Sendable {
    private let countLock = NSLock()
    private var counts = (added: 0, removed: 0)
    var added: Int { countLock.withLock { counts.added } }
    var removed: Int { countLock.withLock { counts.removed } }

    override func addObserver(forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?,
                              using block: @escaping @Sendable (Notification) -> Void) -> NSObjectProtocol {
        countLock.withLock { counts.added += 1 }
        return super.addObserver(forName: name, object: obj, queue: queue, using: block)
    }
    override func removeObserver(_ observer: Any) {
        countLock.withLock { counts.removed += 1 }
        super.removeObserver(observer)
    }
}
