import AppKit

/// The event's meaning is chosen where it happens; localized details and
/// filenames never determine a headline, severity, or available action.
struct NoteNotice: Equatable, Sendable {
    enum Severity: Sendable { case error, caution, information, progress }
    enum Kind: CaseIterable, Sendable {
        case saving, stillSaving, stillReading, damaged, quarantined, copySaved, copyFailed, notDeleted, copyKept, keptSafe, noteSaved, tablePasted, textRestored, notAvailable, notKept, finishFirst, stillAdding, importBusy, imageGone, notSaved, noDuplicate, cancelled, cantCancel, notAdded, historyError, saveFirst, readFailed, notReadable, notRestored, notCleared, textPasted, tableLimit, notPasted, pasteAgain, didntWork, notice
        var headline: String {
            switch self {
            case .saving: String(localized: "Saving…")
            case .stillSaving: String(localized: "Still saving")
            case .stillReading: String(localized: "Still reading")
            case .damaged: String(localized: "Damaged")
            case .quarantined: String(localized: "Quarantined")
            case .copySaved: String(localized: "Copy saved")
            case .copyFailed: String(localized: "Copy failed")
            case .notDeleted: String(localized: "Not deleted")
            case .copyKept: String(localized: "Copy kept")
            case .keptSafe: String(localized: "Kept safe")
            case .noteSaved: String(localized: "Note saved")
            case .tablePasted: String(localized: "Table pasted")
            case .textRestored: String(localized: "Text restored")
            case .notAvailable: String(localized: "Not available")
            case .notKept: String(localized: "Not kept")
            case .finishFirst: String(localized: "Finish first")
            case .stillAdding: String(localized: "Still adding")
            case .importBusy: String(localized: "Import busy")
            case .imageGone: String(localized: "Image gone")
            case .notSaved: String(localized: "Not saved")
            case .noDuplicate: String(localized: "No duplicate")
            case .cancelled: String(localized: "Cancelled")
            case .cantCancel: String(localized: "Can’t cancel")
            case .notAdded: String(localized: "Not added")
            case .historyError: String(localized: "History error")
            case .saveFirst: String(localized: "Save first")
            case .readFailed: String(localized: "Read failed")
            case .notReadable: String(localized: "Not readable")
            case .notRestored: String(localized: "Not restored")
            case .notCleared: String(localized: "Not cleared")
            case .textPasted: String(localized: "Text pasted")
            case .tableLimit: String(localized: "Table limit")
            case .notPasted: String(localized: "Not pasted")
            case .pasteAgain: String(localized: "Paste again")
            case .didntWork: String(localized: "Didn’t work")
            case .notice: String(localized: "Notice")
            }
        }
        var severity: Severity {
            switch self {
            case .copyFailed, .notDeleted, .notSaved, .noDuplicate, .cantCancel, .notAdded, .notRestored, .notCleared, .didntWork: .error
            case .damaged, .copyKept, .keptSafe, .notAvailable, .notKept, .imageGone, .historyError, .readFailed, .notReadable, .notPasted: .caution
            case .quarantined, .copySaved, .noteSaved, .tablePasted, .textRestored, .finishFirst, .importBusy, .cancelled, .saveFirst, .textPasted, .tableLimit, .pasteAgain, .notice: .information
            case .saving, .stillSaving, .stillReading, .stillAdding: .progress
            }
        }
    }
    let kind: Kind
    let severity: Severity
    let detail: String
    init(kind: Kind, severity: Severity? = nil, detail: String) {
        self.kind = kind
        self.severity = severity ?? kind.severity
        self.detail = detail
    }
}


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

    static var allNoticeHeadlines: [String] { Array(Set(NoteNotice.Kind.allCases.map(\.headline))).sorted() }

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
