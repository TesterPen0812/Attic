import Foundation
import SwiftData

/// Store-scoped completion, committed with maintenance; never a user-default flag.
@Model final class StoreMaintenance {
    var key: String = ""
    var noteIDsRaw: String = ""
    var attachmentIDsRaw: String = ""
    var stagedIDsRaw: String = ""
    var filesCleaned: Bool = false
    init(key: String, noteIDs: Set<UUID>, attachmentIDs: Set<UUID>) {
        self.key = key
        noteIDsRaw = NoteVersion.encodeIDs(Array(noteIDs))
        attachmentIDsRaw = NoteVersion.encodeIDs(Array(attachmentIDs))
    }
}
