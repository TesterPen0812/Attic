import AppKit

/// How the status slot words what the page controller reports (UX plan
/// § 3.12): the import's progress, the engine's pending guidance, and the
/// damaged-recovery exit. Pure, so the wording is tested without a view.
enum NoteStatusPresentation {
    /// "Adding 2 of 5" (the file being added now), "Adding a file" for one.
    static func importLabel(_ progress: NoteImportProgress?) -> String {
        guard let progress, progress.total > 1 else { return String(localized: "Adding a file") }
        let current = min(progress.completed + 1, progress.total)
        return String(localized: "Adding \(current) of \(progress.total)")
    }

    /// The details: which files, and how much is copied so far.
    static func importExplanation(_ progress: NoteImportProgress?) -> String {
        guard let progress, !progress.names.isEmpty else {
            return String(localized: "Files are still being added to this note.")
        }
        let names = progress.names.prefix(2).joined(separator: ", ")
        let rest = progress.names.count - 2
        let list = rest > 0 ? String(localized: "\(names) and \(rest) more") : names
        let copied = ByteCountFormatter.string(fromByteCount: progress.copiedBytes, countStyle: .file)
        return String(localized: "\(list). \(progress.completed) of \(progress.total) ready, \(copied) copied. You can keep writing; Cancel Batch leaves the note as it was.")
    }

    /// The engine's guidance after a slow disk: an action that did finish
    /// while its recovery write is still going. Said quietly, as progress
    /// (a spinner, no Dismiss), never as "Try again": it clears itself when
    /// the write lands. The "Try again" wording stays for an action that
    /// did not finish.
    static let progressNotices: Set<String> = [
        "Saving recovery data…",
        "Recovery data is still being saved.",
        "Attachment data is still being read."
    ]

    static func isProgress(_ notice: String) -> Bool { progressNotices.contains(notice) }

    // MARK: Notice headlines (design review D-05)

    /// A notice is a full sentence, which the status pill cut off ("An image
    /// is un…"). The pill says a short headline that fits the slot at the
    /// default 320 pt panel, beside its glyph and close button, and the
    /// details pop-over keeps the full sentence. Matching is by the words
    /// that identify a notice (first rule wins), so a sentence that carries
    /// a changing part (a file name, a system error) still finds its
    /// headline; anything unrecognised gets one of the two fallbacks.
    static let noticeRules: [(match: [String], headline: String)] = [
        (["Saving recovery data"], "Saving…"),
        (["Recovery data is still being saved"], "Still saving"),
        (["Attachment data is still being read"], "Still reading"),
        (["Recovery data is damaged"], "Damaged"),
        (["Damaged recovery was moved"], "Quarantined"),
        (["Recovery copy saved"], "Copy saved"),
        (["recovery copy couldn’t be saved"], "Copy failed"),
        (["old recovery copy of this note couldn’t be cleared"], "Not deleted"),
        (["old recovery copy"], "Copy kept"),
        (["Saved recovery is being kept"], "Kept safe"),
        (["Saved as a new note"], "Note saved"),
        (["Pasted as a table"], "Table pasted"),
        (["Restored unsaved text"], "Text restored"),
        (["Writing Tools unavailable"], "Not available"),
        (["Writing Tools changed"], "Not kept"),
        (["Writing Tools", "composing text"], "Finish first"),
        (["Images are still being added"], "Still adding"),
        (["current file import"], "Import busy"),
        (["An image is unavailable"], "Image gone"),
        (["Couldn’t save a new note"], "Not saved"),
        (["was not deleted"], "Not deleted"),
        (["before deleting it"], "Not deleted"),
        (["before duplicating it", "can’t be duplicated", "couldn’t be duplicated"], "No duplicate"),
        (["file batch was cancelled"], "Cancelled"),
        (["could not be cancelled"], "Can’t cancel"),
        (["clipboard image could not be staged"], "Not added"),
        (["not added", "could not be added"], "Not added"),
        (["Version history could not be read"], "History error"),
        (["before opening version history"], "Save first"),
        (["Proposals could not be read"], "Read failed"),
        (["place in the note could not be read"], "Not readable"),
        (["deletion proposal could not be restored"], "Not restored"),
        (["Attribution could not be acknowledged"], "Not cleared"),
        (["pasted as text"], "Text pasted"),
        (["larger than", "A table can have at most"], "Table limit"),
        (["Nothing was pasted", "nothing was pasted"], "Not pasted"),
        (["Paste again"], "Paste again"),
    ]

    /// For a sentence no rule knows: a problem, or plain news.
    static let problemFallbackHeadline = "Didn’t work"
    static let newsFallbackHeadline = "Notice"

    /// Every headline a notice can have: the rules' and the fallbacks'.
    static var allNoticeHeadlines: [String] {
        var seen = Set<String>()
        return (noticeRules.map(\.headline) + [problemFallbackHeadline, newsFallbackHeadline]).filter { seen.insert($0).inserted }
    }

    /// A notice that needs a look but lost nothing: something couldn't be
    /// read (an attachment, images in a copy). It takes the amber icon;
    /// other notices keep the grey one (colour pass, owner 2026-10-10).
    static func isCaution(notice message: String) -> Bool {
        let lowered = message.localizedLowercase
        return ["couldn’t be read", "couldn't be read", "could not be read", "can’t read", "can't read", "couldn’t read", "couldn't read"]
            .contains(where: lowered.contains)
    }

    /// The pill's words for a notice: short, whatever the sentence.
    static func headline(forNotice message: String) -> String {
        for rule in noticeRules where rule.match.contains(where: message.contains) { return rule.headline }
        let problem = ["couldn’t", "couldn't", "could not", "can’t", "can't", "cannot", "not ", "failed", "unavailable"]
        return problem.contains(where: message.localizedLowercase.contains) ? problemFallbackHeadline : newsFallbackHeadline
    }

    /// The page's notice without the damaged-recovery sentences the exit
    /// shows as their own items (nil when nothing else is left).
    static func notice(_ notice: String?, removingDamaged filenames: [String]) -> String? {
        guard var text = notice else { return nil }
        for name in filenames {
            text = text.replacingOccurrences(of: "Recovery data is damaged: \(name).", with: "")
        }
        text = text.trimmingCharacters(in: .whitespaces)
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        return text.isEmpty ? nil : text
    }
}

/// The way out of damaged recovery data (fix round 4, § 3.12's details):
/// Save Recovery Copy first, then Discard Damaged Recovery… only after an
/// explicit confirmation, passing the confirmation token the details gave.
/// Nothing is ever discarded without that confirmation, and an entry whose
/// items cannot all be read offers no Discard at all.
@MainActor
final class NoteDamagedRecoveryExit: ObservableObject {
    enum Outcome: Equatable {
        case saved(URL)
        case discarded
        case cancelled
        case refused(String)
    }

    @Published private(set) var entries: [NoteDamagedRecoveryDetails] = []

    /// The controller's status command (tests pass their own).
    var perform: (NoteStatusCommand) async -> NoteStatusCommandResult
    /// Asks the person to confirm the discard (an alert; tests answer).
    var confirmDiscard: (NoteDamagedRecoveryDetails) async -> Bool = NoteDamagedRecoveryExit.confirmWithAlert
    /// Where the copy goes (an open panel for a folder; tests answer).
    var chooseFolder: () async -> URL? = NoteDamagedRecoveryExit.chooseFolderWithPanel

    init(perform: @escaping (NoteStatusCommand) async -> NoteStatusCommandResult) {
        self.perform = perform
    }

    func refresh() async {
        if case let .damagedList(list) = await perform(.listDamagedRecovery) { entries = list }
    }

    func saveCopy(_ details: NoteDamagedRecoveryDetails) async -> Outcome {
        guard let folder = await chooseFolder() else { return .cancelled }
        switch await perform(.saveDamagedRecoveryCopy(details.confirmation, folder)) {
        case let .archived(url): return .saved(url)
        case let .unavailable(message): return .refused(message)
        default: return .refused(String(localized: "The recovery copy could not be saved."))
        }
    }

    func discard(_ details: NoteDamagedRecoveryDetails) async -> Outcome {
        guard details.confirmation.canDiscard else {
            return .refused(String(localized: "Some of this recovery data cannot be read yet, so it cannot be discarded."))
        }
        guard await confirmDiscard(details) else { return .cancelled }
        let result = await perform(.discardDamagedRecovery(details.confirmation))
        await refresh()
        switch result {
        case .archived: return .discarded
        case let .unavailable(message): return .refused(message)
        default: return .refused(String(localized: "The damaged recovery data could not be moved."))
        }
    }

    static func confirmWithAlert(_ details: NoteDamagedRecoveryDetails) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Discard the damaged recovery data?")
        alert.informativeText = String(localized: "Attic moves it, with every file it may own, to a quarantine folder; nothing is deleted. Save Recovery Copy first if you may need it.")
        // Cancel is the default (Return and Esc); Discard is a deliberate click.
        alert.addButton(withTitle: String(localized: "Cancel"))
        let discard = alert.addButton(withTitle: String(localized: "Discard"))
        discard.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    static func chooseFolderWithPanel() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Save Copy Here")
        panel.message = String(localized: "Choose a folder for the recovery copy.")
        return panel.runModal() == .OK ? panel.url : nil
    }
}
