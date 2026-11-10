import AppKit

/// A watched run's note edit, shown being written (the design's `noteAct`,
/// Accepted 2026-11-06: "the living spark does the work", "open means
/// watching"). Notes comes forward on the note, the added text appears as it
/// is written with the spark at the writing point, and the chat comes back.
///
/// The edit is already saved when this starts. It only presents it: a veil
/// over the text not yet "written", never a change to the note, so quitting
/// mid-way leaves the whole edit saved and Undo restores the note as before.
@MainActor
final class AgentNoteWriter {
    struct Pace: Equatable {
        /// The design's: 26 ms a character, 150 ms a new line.
        var character: TimeInterval = 0.026
        var newline: TimeInterval = 0.15
        /// The longest the writing takes: a longer edit writes faster, so it
        /// never keeps you waiting (the design's checklist takes 2.8 s).
        var cap: TimeInterval = 3
        /// From the note coming forward to the first character.
        var arrive: TimeInterval = 0.45
        /// After the last character, before the chat comes back (the design's 380 ms).
        var settle: TimeInterval = 0.38
        /// Shown plainly (Reduced, or text replaced): how long the note is
        /// on show before the chat comes back.
        var hold: TimeInterval = 0.9
        var frame: TimeInterval = 1.0 / 60

        static let instant = Pace(character: 0, newline: 0, cap: 0, arrive: 0, settle: 0, hold: 0, frame: 0)
    }

    /// Brings Notes forward on the note and hands back its editor once it is
    /// on show. Called only while the chat is open. Given the text from
    /// before, the added text is hidden from the first frame the page draws.
    private let open: (UUID, NoteDocument?) async -> AgentNoteSurface?
    /// The note's text from just before the agent's write (`NoteStore`).
    private let base: (UUID) -> NoteDocument?
    var pace = Pace()
    var reducesMotion: () -> Bool = { false }

    init(open: @escaping (UUID, NoteDocument?) async -> AgentNoteSurface?, base: @escaping (UUID) -> NoteDocument?) {
        self.open = open
        self.base = base
    }

    /// The presentation for a note the agent has just written in, or nil when
    /// there is nothing to show (the edit is waiting as a proposal, or the
    /// note is not one Notes shows).
    func presentation(for noteID: UUID, watching: @escaping () -> Bool,
                      point: @escaping (CGPoint, Bool) -> Void) -> (() async -> Void)? {
        guard watching(), let before = base(noteID) else { return nil }
        return { [self] in await write(noteID: noteID, before: before, watching: watching, point: point) }
    }

    private func write(noteID: UUID, before: NoteDocument, watching: @escaping () -> Bool,
                       point: (CGPoint, Bool) -> Void) async {
        guard watching(), !Task.isCancelled,
              let surface = await open(noteID, reducesMotion() ? nil : before) else { return }
        // However it ends, nothing stays hidden.
        defer { surface.liftAgentVeil() }
        guard watching(), !Task.isCancelled else { return }
        let insertion = surface.agentInsertion(since: before)
        // Reduced, or text replaced or removed: the note as it is now, plainly.
        surface.keepKeyboardOff()
        guard !reducesMotion(), let insertion, !insertion.replaces, insertion.range.length > 0 else {
            await pause(pace.hold, while: watching) { surface.keepKeyboardOff() }
            return
        }
        let schedule = Self.schedule(surface.agentText(in: insertion.range), pace: pace)
        // The spark waits at the writing point while the note settles in.
        var at = surface.veilAgentWriting(insertion.range, shown: 0).map { CGPoint(x: $0.maxX + 8, y: $0.midY) }
        await pause(pace.arrive, while: watching) {
            surface.keepKeyboardOff()
            // The page is still settling in: the veil and the spark follow it.
            if let caret = surface.veilAgentWriting(insertion.range, shown: 0) {
                at = CGPoint(x: caret.maxX + 8, y: caret.midY)
            }
            if let at { point(at, false) }
        }
        let start = Date()
        var shown = 0
        var next = 0
        while next < schedule.count, watching(), !Task.isCancelled {
            let elapsed = Date().timeIntervalSince(start)
            var star = false
            while next < schedule.count, schedule[next].at <= elapsed {
                shown = schedule[next].end
                // A star every third character, as the design's.
                if next % 3 == 0, !schedule[next].isSpace { star = true }
                next += 1
            }
            if let caret = surface.veilAgentWriting(insertion.range, shown: shown) {
                at = CGPoint(x: caret.maxX + 8, y: caret.midY)
            }
            if let at { point(at, star) }
            surface.keepKeyboardOff()
            if pace.frame > 0 { try? await Task.sleep(for: .seconds(pace.frame)) } else { await Task.yield() }
        }
        surface.liftAgentVeil()
        guard watching(), !Task.isCancelled else { return }
        await pause(pace.settle, while: watching) {
            surface.keepKeyboardOff()
            if let at { point(at, false) }
        }
    }

    /// The Notes page opens the note, as a followed link does, and comes
    /// forward; then its editor, once it is in the window and laid out. A
    /// task's own note is not a Notes page note: nothing opens.
    static func openInNotes(_ noteID: UUID, before: NoteDocument?, pages: NotesPageController?,
                            select: () -> Void) async -> AgentNoteSurface? {
        guard let pages, let note = pages.store.note(withID: noteID), note.taskID == nil,
              await pages.openFromLibrary(noteID: noteID) else { return nil }
        // As a library row does: the note, not the list, is on show.
        if pages.isLibraryPresented { pages.dismissLibrary() }
        // The added text is hidden before the page is drawn, not after.
        var veiled: NoteEditorEngine?
        if let before, let engine = pages.active.flatMap({ $0.noteID == noteID ? $0.engine : nil }),
           let insertion = engine.agentInsertion(since: before), !insertion.replaces, insertion.range.length > 0 {
            engine.agentVeil = insertion.range
            veiled = engine
        }
        select()
        for _ in 0..<45 {
            if let session = pages.active, session.noteID == noteID, let view = session.engine.textView,
               view.window != nil, !view.visibleRect.isEmpty {
                view.keepKeyboardOff()
                // One more frame, so the page's arrival has drawn the note.
                try? await Task.sleep(for: .milliseconds(16))
                return view
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        veiled?.textView?.liftAgentVeil()
        veiled?.agentVeil = nil
        return nil
    }

    /// When each character of `text` appears, from the first, and where it
    /// ends in UTF-16. The whole is squeezed to `pace.cap` when longer.
    static func schedule(_ text: String, pace: Pace) -> [(at: TimeInterval, end: Int, isSpace: Bool)] {
        var steps: [(at: TimeInterval, end: Int, isSpace: Bool)] = []
        var time: TimeInterval = 0
        var end = 0
        for character in text {
            end += character.utf16.count
            steps.append((time, end, character.isWhitespace))
            time += character.isNewline ? pace.newline : pace.character
        }
        let total = steps.last?.at ?? 0
        guard total > pace.cap, total > 0 else { return steps }
        let squeeze = pace.cap / total
        return steps.map { ($0.at * squeeze, $0.end, $0.isSpace) }
    }

    /// Waits `seconds`, or less once the chat closes.
    private func pause(_ seconds: TimeInterval, while watching: () -> Bool, each tick: () -> Void = {}) async {
        guard seconds > 0 else { return await Task.yield() }
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, watching(), !Task.isCancelled {
            tick()
            try? await Task.sleep(for: .seconds(max(0.001, min(0.05, end.timeIntervalSinceNow))))
        }
    }
}
