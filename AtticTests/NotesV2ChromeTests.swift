import AppKit
import SwiftUI
import XCTest
@testable import Attic

/// Notes v2, round 1: chrome B (32 pt corner controls 16 pt from the
/// panel's edges, in Notes and Tasks) and the panel always fitting its
/// window (owner, 2026-10-08: the corner buttons were cut off at the left and
/// right edges).
@MainActor
final class NotesV2ChromeTests: XCTestCase {
    private let defaultCorner = PanelCornerSize.defaultValue

    // MARK: Tokens

    func testChromeBTokens() {
        XCTAssertEqual(AtticControlSize.headerControl, 32)
        XCTAssertEqual(AtticControlSize.panelButton, CGSize(width: 32, height: 32))
        XCTAssertEqual(AtticControlSize.addBarHeight, 32)
        XCTAssertEqual(AtticControlSize.sendButton, CGSize(width: 24, height: 24))
        XCTAssertEqual(AtticStyle.chromeMinimumInset, 16)
        XCTAssertEqual(AtticRadius.control(height: AtticControlSize.headerControl), 13.5, "the 42 % rule")
        XCTAssertEqual(AtticPageButtonMetrics.segment, 24)
        XCTAssertEqual(AtticNoteFormatMetrics.rowCellHeight, 24)
        XCTAssertEqual(AtticNoteMetrics.pillHeight, 32)
        XCTAssertEqual(AtticNoteMetrics.formatButtonGap, 6)
        XCTAssertEqual(AtticControlSize.raisedGlyph, 13)
    }

    /// Every control keeps at least a 28 pt target: the 32 pt buttons by
    /// their size, the 24 pt chips and cells by reaching 2 pt past their edge.
    func testHitTargetsStayAtLeast28() {
        let minimum = AtticControlSize.minimumHitTarget
        XCTAssertGreaterThanOrEqual(AtticControlSize.panelButton.height, minimum)
        XCTAssertGreaterThanOrEqual(AtticControlSize.addBarHeight, minimum)
        for side in [AtticPageButtonMetrics.segment, AtticNoteFormatMetrics.rowCellHeight, AtticControlSize.sendButton.height] {
            XCTAssertEqual(side + 2 * AtticControlSize.hitOutset(for: side), minimum, "side \(side)")
        }
        XCTAssertEqual(AtticControlSize.hitOutset(for: 32), 0)
    }

    // MARK: Lines

    /// The controls sit 16 in; the content line (the note's column, the
    /// Tasks circles and tabs) stays at 28, and the add bar's plus on the
    /// circles' centre line (36).
    func testContentLineStaysAt28AndTheAddBarPlusOnTheCircles() {
        let layout = PanelPageLayout(cornerSize: defaultCorner, panelSize: CGSize(width: 320, height: 520))
        XCTAssertEqual(layout.chromeInsets.leading, 16)
        XCTAssertEqual(layout.headerBottom, 48)
        XCTAssertEqual(layout.chromeInsets.leading + AtticNoteMetrics.columnInset, 28, "the note's column")
        let tasksPageEdge = layout.chromeInsets.leading + AtticLayout.contentFromChrome - AtticLayout.circleX
        XCTAssertEqual(tasksPageEdge + AtticLayout.circleX, 28, "the Tasks circles")
        let plusCentre = layout.chromeInsets.leading + AtticAddBarMetrics.leadingPadding + AtticAddBarMetrics.iconSlot / 2
        XCTAssertEqual(plusCentre, 28 + AtticControlSize.statusCircle / 2, "the plus on the circles' centre line")
        XCTAssertEqual(plusCentre + AtticAddBarMetrics.iconSlot / 2 + AtticAddBarMetrics.gap, 56, "the text on the titles' line")
        // The draft (v2-04): the title's first line at 64, the last line 12
        // above the bottom row (whose top is 48 from the bottom).
        XCTAssertEqual(layout.headerBottom + AtticNoteMetrics.titleTopGap, 64)
        XCTAssertEqual(layout.chromeInsets.bottom + AtticControlSize.panelButton.height + AtticSpacing.s12, 60)
    }

    /// Larger corners push the controls and the content line in together.
    func testLargerCornersMoveTheControlsAndTheContentLineTogether() {
        let size = CGSize(width: 320, height: 520)
        var last: CGFloat = 0
        for corner in PanelCornerSize.allCases.map(\.rawValue) {
            let insets = PanelGeometry.chromeInsets(cornerSize: corner, panelSize: size)
            XCTAssertGreaterThanOrEqual(insets.leading, 16)
            XCTAssertGreaterThanOrEqual(insets.leading, last)
            last = insets.leading
        }
    }

    // MARK: The bottom row never outgrows the panel

    /// The status pill takes only the room the bottom row leaves, so the
    /// row (All notes, the pill, Aa, New note) fits every panel width the
    /// settings allow and every corner size. Before, 176 pt of pill plus
    /// three 36 pt buttons needed 364 pt in a 320 pt panel: the row grew
    /// past the panel and was centred, cutting both corner buttons off.
    func testBottomRowFitsEveryPanelWidthAndCorner() {
        let widths = PanelContentSize.allCases.map(\.rawValue) + [PanelGeometry.minimumPanelSize.width, 333, 500]
        for width in widths {
            for corner in PanelCornerSize.allCases.map(\.rawValue) {
                let layout = PanelPageLayout(cornerSize: corner, panelSize: CGSize(width: width, height: 520))
                for showsFormat in [true, false] {
                    let pill = AtticNoteMetrics.pillMaxWidth(panelWidth: width, chromeInset: layout.chromeInsets.leading,
                                                             showsFormat: showsFormat)
                    let buttons = AtticControlSize.panelButton.width * (showsFormat ? 3 : 2)
                        + (showsFormat ? AtticNoteMetrics.formatButtonGap : 0)
                    let row = layout.chromeInsets.leading * 2 + buttons + AtticSpacing.s12 * 2 + pill
                    XCTAssertLessThanOrEqual(row, width + 0.001, "width \(width), corner \(corner), Aa \(showsFormat)")
                    XCTAssertLessThanOrEqual(pill, AtticNoteMetrics.pillMaxWidth)
                }
            }
        }
        // The default 320 pt panel: 162 pt for the pill beside Aa.
        XCTAssertEqual(AtticNoteMetrics.pillMaxWidth(panelWidth: 320, chromeInset: 16, showsFormat: true), 162)
    }

    // MARK: The root fills its window, whatever its content asks

    func testRootLayoutPlacesOverwideContentAtTheWindowsSizeFromItsOrigin() throws {
        for width in [320, 360, 380, 341.5] as [CGFloat] {
            let host = NSHostingView(rootView: PanelRootLayout {
                ZStack {
                    // A child far wider than the panel (an overflowing row).
                    Color.clear.frame(width: 900, height: 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            })
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: width, height: 520)
            host.layoutSubtreeIfNeeded()
            let placed = try XCTUnwrap(PanelRootLayout.lastPlacedSize)
            XCTAssertEqual(placed.width, width, accuracy: 0.001)
            XCTAssertEqual(placed.height, 520, accuracy: 0.001)
            XCTAssertEqual(host.frame.size, CGSize(width: width, height: 520), "the content never resizes the host")
        }
    }

    /// The real panel, hidden: for every width and height the settings
    /// allow, and for every frame of a live resize between them, the
    /// window's visible frame, the hosting view, the page layout's size and
    /// the size SwiftUI lays the root out at are the same.
    func testPanelWindowAlwaysFitsItsContentForEveryPanelSize() throws {
        let suite = "NotesV2ChromeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: persistence)
        let notes = trackAttachmentReconciliation(of: NoteStore(container: persistence, attachmentFileStore: makeTestAttachmentFileStore()))
        let settings = AppSettings(defaults: defaults)
        let uiState = PanelUIState()
        let existingWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let controller = AtticPanelController(
            store: store, noteStore: notes,
            canvasSession: CanvasSession(store: CanvasStore(container: persistence)),
            noteDraft: NoteDraftController(noteStore: notes), settings: settings, uiState: uiState
        )
        let panel = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? AtticPanel }
            .first { !existingWindows.contains(ObjectIdentifier($0)) })
        let container = try XCTUnwrap(panel.contentView as? AtticPanelContentContainer)
        XCTAssertFalse(panel.isVisible, "This regression must not display a test window")

        func assertFits(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
            container.layoutSubtreeIfNeeded()
            container.hostingView.layoutSubtreeIfNeeded()
            let visible = panel.visibleContentFrame.size
            XCTAssertEqual(container.hostingView.frame.size.width, visible.width, accuracy: 0.01, label, file: file, line: line)
            XCTAssertEqual(container.hostingView.frame.size.height, visible.height, accuracy: 0.01, label, file: file, line: line)
            XCTAssertEqual(uiState.panelSize.width, visible.width, accuracy: 0.5, label, file: file, line: line)
            guard let placed = PanelRootLayout.lastPlacedSize else {
                return XCTFail("the root was never laid out: \(label)", file: file, line: line)
            }
            XCTAssertEqual(placed.width, visible.width, accuracy: 0.01, "SwiftUI's root, \(label)", file: file, line: line)
            XCTAssertEqual(placed.height, visible.height, accuracy: 0.01, "SwiftUI's root, \(label)", file: file, line: line)
        }

        // Every width setting, there and back (the slider is live).
        let sizes = PanelContentSize.allCases.map(\.rawValue)
        for width in sizes + sizes.reversed() {
            settings.panelContentSize = width
            assertFits("width setting \(width)")
        }
        // Every corner size at every width: the frame stays, the content follows.
        for corner in PanelCornerSize.allCases.map(\.rawValue) {
            settings.panelCornerSize = corner
            for width in sizes {
                settings.panelContentSize = width
                assertFits("corner \(corner), width \(width)")
            }
        }
        settings.panelCornerSize = PanelCornerSize.defaultValue
        // A live resize: every intermediate frame, wider and narrower.
        let start = panel.visibleContentFrame
        for step in stride(from: 0, through: 60, by: 7.5) {
            for delta in [step, -step] where start.width + delta >= PanelGeometry.minimumPanelSize.width {
                var frame = start
                frame.size.width += delta
                frame.size.height += delta / 2
                panel.setVisibleContentFrame(frame, display: false)
                assertFits("live resize to \(frame.size)")
            }
        }
        withExtendedLifetime(controller) {}
    }

    /// A39 F08, the owner's repro: a note with a table is open and Settings
    /// changes the panel's width (420 → 320 → 420). The note editor and every
    /// page that is built fill the panel's content rect at once, every time,
    /// and again after switching pages. Nothing keeps its old width or is cut
    /// by the window's edge. The real panel, hidden.
    func testNotesFollowsAWidthChangeAndPageSwitchesWithoutClipping() throws {
        let suite = "NotesV2ChromeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = try PersistenceController.makeContainer(inMemory: true, cloudSyncEnabled: false)
        let store = TaskStore(container: persistence)
        let notes = trackAttachmentReconciliation(of: NoteStore(container: persistence, attachmentFileStore: makeTestAttachmentFileStore()))
        let settings = AppSettings(defaults: defaults)
        settings.panelContentSize = 420
        let uiState = PanelUIState()
        let drafts = NoteDraftController(noteStore: notes)
        let existingWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let controller = AtticPanelController(
            store: store, noteStore: notes,
            canvasSession: CanvasSession(store: CanvasStore(container: persistence)),
            noteDraft: drafts, settings: settings, uiState: uiState
        )
        let panel = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? AtticPanel }
            .first { !existingWindows.contains(ObjectIdentifier($0)) })
        let container = try XCTUnwrap(panel.contentView as? AtticPanelContentContainer)
        XCTAssertFalse(panel.isVisible, "This regression must not display a test window")

        uiState.selectSection(.notes)
        controller.preparePagesForReveal()
        drafts.pages.start()
        XCTAssertTrue(drafts.pages.newNote())
        let session = try XCTUnwrap(drafts.pages.active)
        let table = NoteTable(texts: [["Pillar", "What happened", "Control that failed", "Source"],
                                      ["Confidentiality", "Data taken from the IT network", "No MFA on the VPN account", "beerman2023review"]])
        _ = session.engine.insertTable(table, replacing: NSRange(location: session.engine.textStorage.length, length: 0),
                                       name: "Insert Table", entering: false)

        func spin() {
            for _ in 0..<4 {
                container.layoutSubtreeIfNeeded()
                container.hostingView.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
        func editor() -> NSScrollView? {
            func find(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView, scroll.documentView is NoteEditorTextView { return scroll }
                for sub in view.subviews { if let found = find(sub) { return found } }
                return nil
            }
            return find(container.hostingView)
        }
        func assertFills(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
            spin()
            let visible = panel.visibleContentFrame.size
            guard let scroll = editor() else { return XCTFail("no note editor: \(label)", file: file, line: line) }
            let frame = scroll.convert(scroll.bounds, to: container.hostingView)
            XCTAssertEqual(frame.width, visible.width, accuracy: 0.5, "the note fills the panel's width, \(label)", file: file, line: line)
            XCTAssertEqual(frame.minX, 0, accuracy: 0.5, "from the panel's edge, \(label)", file: file, line: line)
            let placed = PanelRootLayout.lastPlacedSize
            XCTAssertEqual(placed?.width ?? -1, visible.width, accuracy: 0.5, "the root, \(label)", file: file, line: line)
        }

        // The page restores its session on the next turns.
        let deadline = Date().addingTimeInterval(3)
        while editor() == nil, Date() < deadline { spin() }
        assertFills("at 420")
        for width in [320, 420, 360, 320, 380, 420] as [Double] {
            settings.panelContentSize = width
            assertFills("width \(width)")
        }
        // Switching pages after the change (Notes stays built behind Tasks).
        settings.panelContentSize = 320
        for section in [PanelSection.tasks, .notes, .tasks, .notes] {
            uiState.selectSection(section)
            if section == .notes {
                let wait = Date().addingTimeInterval(3)
                while editor() == nil, Date() < wait { spin() }
                assertFills("320, after switching to \(section)")
            } else {
                spin()
            }
        }
        settings.panelContentSize = 420
        uiState.selectSection(.tasks)
        settings.panelContentSize = 320
        uiState.selectSection(.notes)
        let wait = Date().addingTimeInterval(3)
        while editor() == nil, Date() < wait { spin() }
        assertFills("narrowed while Notes was behind another page")
        withExtendedLifetime(controller) {}
    }
}
