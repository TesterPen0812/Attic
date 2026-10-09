import Foundation

/// Read-only ownership proof for one-time maintenance. Unlike journal recovery,
/// this never retires checkpoints or collects files while inventorying them.
struct NoteRecoveryMaintenanceSnapshot {
    let stagedIDs: Set<UUID>
    let documentIDs: Set<UUID>

    static func read(_ file: URL, directory: URL) throws -> Self {
        let data = try Data(contentsOf: file)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(NoteDraftJournalEntry.self, from: data)
        guard file.deletingPathExtension().lastPathComponent == entry.noteID.uuidString,
              case let .editable(document) = NoteContentCodec.decode(entry.content),
              Set(entry.staged.map(\.id)).count == entry.staged.count,
              Set(entry.pendingImport?.items.compactMap(\.stagedID) ?? []).isSubset(of: Set(entry.staged.map(\.id))) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let retired = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["retired"] as? Bool == true
        if retired {
            guard entry.staged.isEmpty, entry.pendingImport == nil else { throw CocoaError(.fileReadCorruptFile) }
            return Self(stagedIDs: [], documentIDs: [])
        }
        for staged in entry.staged {
            let url = directory.appendingPathComponent("staged", isDirectory: true).appendingPathComponent(staged.id.uuidString)
            guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else { throw CocoaError(.fileReadNoPermission) }
            let bytes = try Data(contentsOf: url)
            guard Int64(bytes.count) == staged.byteCount, NotePayloadDigest.sha256(bytes) == staged.digest else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        return Self(stagedIDs: Set(entry.staged.map(\.id)), documentIDs: Set(document.attachmentIDs))
    }
}
