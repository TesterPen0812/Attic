import Foundation

/// What a command did, told to the surface that started it (Astra 6): the
/// quick look that ticked a subtask, the row that was deleted or dragged,
/// the toast whose Undo was pressed. A surface moves focus, closes an
/// editor or gives success feedback only on `.applied`; on `.failed` it
/// keeps the person's place and shows the reason where they are working,
/// with Retry when retrying can help.
enum CommandOutcome: Equatable {
    /// The store saved the change (or nothing needed to change).
    case applied
    /// Nothing changed: the store is exactly as it was before the command.
    case failed(CommandFailure)

    var isApplied: Bool { self == .applied }

    var failure: CommandFailure? {
        if case let .failed(failure) = self { return failure }
        return nil
    }
}

/// Why a command changed nothing.
struct CommandFailure: Error, Equatable {
    /// The store's own sentence, fit to show where the person is working
    /// ("Not saved" and Retry beside it). Always set, also for failures the
    /// store files under a family (`TaskStore.ErrorNotice.owner`): the
    /// outcome goes to the surface that started the command, whichever
    /// panel owns the notice.
    let message: String
    /// False when retrying cannot help: what the command changes is gone
    /// (deleted, in Recently Deleted, removed for good) or was changed since
    /// in every field it touches. Show the message without Retry and drop
    /// the pending edit.
    let canRetry: Bool

    init(_ message: String, canRetry: Bool = true) {
        self.message = message
        self.canRetry = canRetry
    }

    static let taskGone = CommandFailure(String(localized: "This task is no longer in your lists."), canRetry: false)
}
