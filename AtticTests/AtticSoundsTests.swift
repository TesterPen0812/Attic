import AppKit
import XCTest
@testable import Attic

/// Sounds (Planning.md Accepted 2026-11-10): the cue each action plays, the
/// 60 ms gap, the switches that silence them, the moments that never play,
/// and the files every cue needs.
@MainActor
final class AtticSoundsTests: XCTestCase {
    /// What the shared player let through. Every request is a second after
    /// the one before, so separate actions never fall into each other's gap:
    /// one action playing once is the action's own doing.
    private final class Log {
        var cues: [AtticSounds.Cue] = []
        var time: TimeInterval = 10_000
    }

    private func listen() -> Log {
        let log = Log()
        let sounds = AtticSounds.shared
        sounds.lastPlayed = -.infinity
        sounds.settingEnabled = { true }
        sounds.systemAllows = { true }
        sounds.clock = { log.time += 1; return log.time }
        sounds.output = { log.cues.append($0) }
        addTeardownBlock { @MainActor in
            sounds.settingEnabled = nil
            sounds.output = nil
            sounds.systemAllows = { true }
            sounds.clock = { ProcessInfo.processInfo.systemUptime }
            sounds.lastPlayed = -.infinity
        }
        return log
    }

    private func makeModel(_ titles: [String]) throws -> (TasksPageModel, [UUID]) {
        let store = try makeTestStore()
        let ids = titles.compactMap { store.create(title: $0)?.id }
        XCTAssertEqual(ids.count, titles.count)
        return (TasksPageModel(library: AtticLibrary(tasks: store)), ids)
    }

    // MARK: The player

    func testCuesCloserThanSixtyMillisecondsPlayOnce() {
        let sounds = AtticSounds()
        var now: TimeInterval = 5
        var played: [AtticSounds.Cue] = []
        sounds.settingEnabled = { true }
        sounds.systemAllows = { true }
        sounds.clock = { now }
        sounds.output = { played.append($0) }

        XCTAssertTrue(sounds.play(.done))
        now += 0.059
        XCTAssertFalse(sounds.play(.created), "inside the gap")
        now += 0.002
        XCTAssertTrue(sounds.play(.trashed), "61 ms after the last one that played")
        XCTAssertEqual(played, [.done, .trashed])
        XCTAssertEqual(AtticSounds.minimumGap, 0.06)
    }

    func testSilentUntilConnectedAndWhileEitherSwitchIsOff() {
        let sounds = AtticSounds()
        var played: [AtticSounds.Cue] = []
        sounds.systemAllows = { true }
        XCTAssertFalse(sounds.play(.done), "never connected: silent")
        sounds.output = { played.append($0) }
        XCTAssertFalse(sounds.play(.done), "no settings: silent")

        var setting = false, system = true
        var now: TimeInterval = 0
        sounds.settingEnabled = { setting }
        sounds.systemAllows = { system }
        sounds.clock = { now += 1; return now }
        XCTAssertFalse(sounds.play(.done), "Settings › General › Sounds off")
        setting = true
        system = false
        XCTAssertFalse(sounds.play(.done), "the Mac's interface sound effects off")
        system = true
        XCTAssertTrue(sounds.play(.done))
        XCTAssertEqual(played, [.done])
    }

    func testTheTestHostNeverConnectsTheSharedPlayer() {
        // Only the real app connects it (AppCoordinator); tests stay silent.
        XCTAssertNil(AtticSounds.shared.settingEnabled)
        XCTAssertNil(AtticSounds.shared.output)
        XCTAssertFalse(AtticSounds.shared.play(.done))
    }

    func testTheSystemSwitchIsTheMacsInterfaceSoundEffectsSetting() {
        let key = "com.apple.sound.uiaudio.enabled"
        let sounds = AtticSounds()
        let stored = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(stored, forKey: key) }
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(sounds.systemAllows())
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(sounds.systemAllows())
    }

    // MARK: Each action's cue

    func testTaskActionsPlayTheirCueOnce() throws {
        let log = listen()
        let (model, ids) = try makeModel(["One", "Two", "Three", "Four"])

        XCTAssertTrue(model.toggleDone(ids[0]).isApplied)
        XCTAssertEqual(log.cues, [.done], "the circle and Space")
        XCTAssertTrue(model.toggleDone(ids[0]).isApplied)
        XCTAssertEqual(log.cues, [.done, .undone])

        log.cues = []
        XCTAssertTrue(model.toggleDone([ids[1], ids[2]]).isApplied)
        XCTAssertEqual(log.cues, [.done], "a batch plays once")
        XCTAssertTrue(model.toggleDone([ids[1], ids[2]]).isApplied)
        XCTAssertEqual(log.cues, [.done, .undone])

        log.cues = []
        XCTAssertTrue(model.delete([ids[3]]).isApplied)
        XCTAssertEqual(log.cues, [.trashed])

        log.cues = []
        let board = NSPasteboard(name: NSPasteboard.Name("AtticSoundsTests-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        XCTAssertTrue(model.copy([ids[0]], to: board))
        XCTAssertEqual(log.cues, [.copied])
    }

    func testAddingATaskPlaysCreatedAndTypingItPlaysNothing() throws {
        let log = listen()
        let (model, _) = try makeModel([])
        for character in "Water the plants" {
            let at = (model.addBar.text as NSString).length
            model.addBarEdited(NSRange(location: at, length: 0), replacement: String(character))
            model.addBar.text += String(character)
            model.addBarCaretMoved((model.addBar.text as NSString).length)
        }
        XCTAssertEqual(log.cues, [], "typing never plays")
        XCTAssertNotNil(model.submitAddBar())
        XCTAssertEqual(log.cues, [.created])
    }

    func testAFailureShownOnARowPlaysFailed() throws {
        let log = listen()
        let (model, ids) = try makeModel(["One"])
        let failure = CommandOutcome.failed(CommandFailure("Not saved"))
        model.report(failure, on: ids[0], retry: { failure })
        XCTAssertEqual(log.cues, [.failed])
        model.report(.applied, on: ids[0], retry: { .applied })
        XCTAssertEqual(log.cues, [.failed], "clearing it is silent")
    }

    func testBrowsingTypingAndFoldingPlayNothing() throws {
        let log = listen()
        let (model, ids) = try makeModel(["One", "Two"])
        model.selectOnly(ids[0])
        model.selectOnly(ids[1])
        model.select(tab: .backlog)
        model.select(tab: .done)
        model.typeDoneSearch("On")
        model.flushDoneSearchInput()
        model.select(tab: .now)
        model.toggleCompletedToday()
        model.toggleCompletedToday()

        let engine = NoteEditorEngine(noteID: UUID(), document: NoteDocument(blocks: [.text("Hello")]), stagedAttachments: [])
        let (scrollView, textView) = engine.makeView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.insertText(" world", replacementRange: textView.selectedRange())
        textView.scroll(NSPoint(x: 0, y: 40))
        XCTAssertEqual(log.cues, [])
    }

    // MARK: Settings › General › Sounds

    func testTheSoundsSwitchIsOnByDefaultAndPlaysDoneWhenTurnedOn() {
        let log = listen()
        let suite = "AtticSoundsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, motionLabAvailable: false)
        XCTAssertTrue(settings.soundsEnabled)

        GeneralSettingsView.setSounds(false, in: settings)
        XCTAssertFalse(settings.soundsEnabled)
        XCTAssertEqual(log.cues, [])
        XCTAssertEqual(AppSettings(defaults: defaults, motionLabAvailable: false).soundsEnabled, false, "kept")

        GeneralSettingsView.setSounds(true, in: settings)
        XCTAssertEqual(log.cues, [.done], "turning it on plays the done sound once")
    }

    // MARK: The files

    func testEveryCueHasAShortQuietFileInTheBundle() throws {
        for cue in AtticSounds.Cue.allCases {
            let url = try XCTUnwrap(AtticSounds.url(of: cue), "\(cue) has no file")
            let sound = try XCTUnwrap(NSSound(contentsOf: url, byReference: true), "\(cue) doesn't load")
            XCTAssertGreaterThan(sound.duration, 0.03, "\(cue)")
            XCTAssertLessThanOrEqual(sound.duration, 0.301, "\(cue)")
            let data = try Data(contentsOf: url)
            let bytes = [UInt8](data.dropFirst(44))
            let samples = stride(from: 0, to: bytes.count - 1, by: 2).map {
                Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)
            }
            let peak = samples.map { abs(Int($0)) }.max() ?? 0
            XCTAssertLessThan(Double(peak) / 32767, 0.36, "\(cue) peaks below -9 dBFS")
            XCTAssertLessThan(abs(Int(samples.first ?? 0)) + abs(Int(samples.last ?? 0)), 8, "\(cue) starts and ends on silence")
        }
    }
}
