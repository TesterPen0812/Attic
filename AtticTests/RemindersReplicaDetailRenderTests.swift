import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Renders the replica's detail panel at 1x for the side-by-side with the
/// study's R2-08 capture (an all-day date, a tag, notes with a link,
/// Notes expanded). The PNG is written only with ATTIC_REPLICA_RENDER=1.
@MainActor
final class RemindersReplicaDetailRenderTests: XCTestCase {
    func testThePanelRendersAtItsEstimatedWidth() throws {
        let clock = MutableNow(Date(timeIntervalSince1970: 1_790_000_000))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let store = try makeTestStore(now: { clock.value })
        let library = AtticLibrary(tasks: store, now: { clock.value })
        let fixed = calendar
        let model = TasksPageModel(library: library, services: TasksPageServices(
            now: { clock.value }, calendar: { fixed }, locale: Locale(identifier: "en_GB"), doneHold: .seconds(3_600)))
        model.setListStyle(.reminders)
        model.addBar.text = "Study R2 gamma #studyR2"
        let id = try XCTUnwrap(model.submitAddBar())
        let day = try XCTUnwrap(DueDay(rawValue: "2026-10-30"))
        XCTAssertTrue(library.updateTask(id, dueDay: .some(day)).isApplied)
        model.setNotePreviews([id: "Study R2 notes https://example.com/notes #studyNotesR2"])
        model.openReplicaDetail(id)
        let detail = try XCTUnwrap(model.replicaDetail)
        detail.notesExpanded = true

        let previous = NSAppearance.current
        NSAppearance.current = NSAppearance(named: .aqua)
        defer { NSAppearance.current = previous }
        let view = NSHostingView(rootView: RemindersReplicaDetailView(state: detail, model: model, openPage: {})
            .environment(\.colorScheme, .light)
            .background(Color.white))
        view.appearance = NSAppearance(named: .aqua)
        let size = view.fittingSize
        XCTAssertEqual(size.width, RemindersReplicaDetailMetrics.panelWidth, accuracy: 0.5, "E: 300 pt cards, 10 pt in (R2-F04)")
        view.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        guard ProcessInfo.processInfo.environment["ATTIC_REPLICA_RENDER"] == "1" else { return }
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attic-replica-render")
        print("ATTIC_REPLICA_RENDER_OUT=\(url.path)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("detail-320.png"))
    }
}
