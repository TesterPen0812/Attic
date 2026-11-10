import AppKit

/// Short, quiet sounds when something the person did lands (Planning.md
/// Accepted 2026-11-10, "Sounds"): a task done or undone, something
/// created, moved to Recently Deleted, restored, Recently Deleted emptied,
/// a dragged row or block dropped, copied, a file attached, a failure.
///
/// A cue names the moment, not the sound. The files are Attic's own,
/// synthesized by `Scripts/generate_sounds.py` into `Resources/Sounds`.
///
/// Never for typing, hovering, scrolling, opening a menu or passing a slot
/// while dragging. Cues closer together than `minimumGap` are dropped, so a
/// command that finishes twenty tasks, or a gesture two layers report,
/// plays once. Silent until the app connects its settings (so tests,
/// previews and the gallery never play), while Settings › General › Sounds
/// is off, and while the Mac's "Play user interface sound effects" is off.
@MainActor
final class AtticSounds {
    enum Cue: String, CaseIterable, Sendable {
        /// A task (or subtask) marked done.
        case done
        /// A done task (or subtask) open again; quieter than `done`.
        case undone
        /// A task, note, event or canvas the person made.
        case created
        /// Moved to Recently Deleted.
        case trashed
        /// Brought back from Recently Deleted.
        case restored
        /// Recently Deleted emptied, or items in it deleted for good.
        case emptied
        /// A dragged row, block or note let go in a new place.
        case dropped
        /// Put on the clipboard by a command: tasks, a link, a path, an image.
        case copied
        /// A file attached to a task or a note.
        case attached
        /// Something the person asked for could not be done.
        case failed
    }

    static let shared = AtticSounds()

    /// At most one sound per 60 ms.
    static let minimumGap: TimeInterval = 0.06

    /// Settings › General › Sounds. Nil (silent) until `connect(_:)`.
    var settingEnabled: (() -> Bool)?
    /// The Mac's System Settings › Sound › "Play user interface sound
    /// effects"; on when never set.
    var systemAllows: () -> Bool = {
        UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool ?? true
    }
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Makes the sound. Replaced by tests.
    var output: ((Cue) -> Void)?

    /// When the last cue played; tests start it over.
    var lastPlayed: TimeInterval = -.infinity
    private var sounds: [Cue: NSSound] = [:]

    init() {}

    /// Where the app plays a cue: `AtticSounds.play(.done)`.
    static func play(_ cue: Cue) {
        shared.play(cue)
    }

    /// Plays `cue` when `outcome` applied a change, and hands the outcome
    /// back, so a call site stays one line.
    @discardableResult
    static func play(_ cue: Cue, after outcome: CommandOutcome) -> CommandOutcome {
        if outcome.isApplied { shared.play(cue) }
        return outcome
    }

    /// Plays `cue` when `succeeded`, and hands it back.
    @discardableResult
    static func play(_ cue: Cue, if succeeded: Bool) -> Bool {
        if succeeded { shared.play(cue) }
        return succeeded
    }

    /// The real app's settings: from now on cues follow the Sounds switch.
    /// The files load here, once, so the first cue plays without a delay.
    func connect(_ settings: AppSettings) {
        settingEnabled = { [weak settings] in settings?.soundsEnabled ?? false }
        output = { [weak self] cue in self?.sound(for: cue)?.playFromStart() }
        for cue in Cue.allCases { _ = sound(for: cue) }
    }

    /// Whether the cue was let through (the tests read it).
    @discardableResult
    func play(_ cue: Cue) -> Bool {
        guard settingEnabled?() == true, systemAllows(), let output else { return false }
        let now = clock()
        guard now - lastPlayed >= Self.minimumGap else { return false }
        lastPlayed = now
        output(cue)
        return true
    }

    /// The cue's file in the app's `Sounds` folder.
    static func url(of cue: Cue, in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: cue.rawValue, withExtension: "wav", subdirectory: "Sounds")
    }

    private func sound(for cue: Cue) -> NSSound? {
        if let sound = sounds[cue] { return sound }
        guard let url = Self.url(of: cue), let sound = NSSound(contentsOf: url, byReference: true) else { return nil }
        sounds[cue] = sound
        return sound
    }
}

private extension NSSound {
    func playFromStart() {
        if isPlaying { stop() }
        play()
    }
}
