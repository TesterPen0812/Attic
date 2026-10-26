import Foundation

/// The New list style's card (council D2, pick 3A): an item's writing,
/// read and written in place as its note (one-item rules), never as a
/// separate field. Plain writing (paragraphs only) is edited in the card;
/// writing with formatting, links, checkboxes or objects is shown and
/// edited on the item's page, so the card can never flatten it.
///
/// Both go through the note's own session: the open page's (panel or
/// window) when there is one, otherwise an engine-only session of the
/// task's workspace under its own lease, which lets go durably
/// (`TaskNoteFiles` does the same for dropped files). A write is the
/// note's own named edit: the gated save, the journal and the note's
/// history, as typing on the page.
@MainActor
enum TaskNoteWriting {
    struct Snapshot: Equatable, Sendable {
        let text: String
        /// Paragraphs only: the card may edit it as plain text.
        let isPlain: Bool
    }

    static func read(_ taskID: UUID, tasks: TaskStore, controller: NotesPageController) async -> Snapshot? {
        await withSession(taskID, tasks: tasks, controller: controller) { session in
            snapshot(of: session.engine)
        }
    }

    /// Replaces plain writing with `text`. Refused (false) when the writing
    /// is no longer plain, or the note can't be edited here.
    static func write(_ text: String, to taskID: UUID, tasks: TaskStore, controller: NotesPageController) async -> Bool {
        await withSession(taskID, tasks: tasks, controller: controller) { session -> Bool in
            let engine = session.engine
            guard let current = snapshot(of: engine), current.isPlain else { return false }
            guard current.text != text else { return true }
            let start = min(engine.bodyStart, engine.textStorage.length)
            let range = NSRange(location: start, length: engine.textStorage.length - start)
            let replacement = NSAttributedString(string: text, attributes: engine.style.bodyAttributes)
            return engine.performEdit(range, with: replacement, name: String(localized: "Edit Writing"))
        } ?? false
    }

    /// The writing after the title (a task's note is body only).
    static func snapshot(of engine: NoteEditorEngine) -> Snapshot? {
        let storage = engine.textStorage
        let start = min(engine.bodyStart, storage.length)
        let range = NSRange(location: start, length: storage.length - start)
        let text = (storage.string as NSString).substring(with: range)
        return Snapshot(text: text, isPlain: isPlain(storage, in: range))
    }

    /// Paragraphs only: no object, link, inline mark, or block style other
    /// than body (headings, lists, checkboxes, quotes and code are kept on
    /// the page).
    static func isPlain(_ text: NSAttributedString, in range: NSRange) -> Bool {
        guard range.length > 0 else { return true }
        if TaskNoteSubtaskSelection.isRich(text, in: range) { return false }
        var plain = true
        text.enumerateAttribute(.noteBlockStyle, in: range) { value, _, stop in
            if let name = value as? String, !name.isEmpty, name != "body" {
                plain = false
                stop.pointee = true
            }
        }
        guard plain else { return false }
        text.enumerateAttribute(.noteBlockIndent, in: range) { value, _, stop in
            if let indent = value as? Int, indent > 0 {
                plain = false
                stop.pointee = true
            }
        }
        return plain
    }

    private static func withSession<T>(_ taskID: UUID, tasks: TaskStore, controller: NotesPageController,
                                       _ body: (NoteSession) async -> T?) async -> T? {
        guard let coordinator = try? WorkspaceLegacyBridge.coordinator(for: tasks.container) else { return nil }
        await coordinator.sessions.retryHeadlessClosures()
        if let presenter = TaskNotePresenter.open(for: taskID) {
            guard let session = presenter.session, !session.isReadOnly else { return nil }
            return await body(session)
        }
        guard let page = try? coordinator.sessions.session(for: .task(taskID), notes: controller),
              let lease = try? page.acquire(surfaceID: UUID()) else { return nil }
        guard let session = page.note, !session.isReadOnly else {
            _ = await coordinator.sessions.closeHeadless(page, lease: lease)
            return nil
        }
        let result = await body(session)
        // Closing preserves durably: a write's save is in before it returns.
        guard await coordinator.sessions.closeHeadless(page, lease: lease) else { return nil }
        return result
    }
}
