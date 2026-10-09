import Foundation
import SwiftData

/// The owner's 2026-10-09 decision: remove format zero, once per store.
/// A durable marker and all database deletions share one save. File cleanup
/// uses its frozen ownership manifest and completes before recovery can start.
enum OldNotesPurge {
    static let key = "old-notes-removal-2026-10-09"
    struct Counts: Equatable { var notes = 0; var attachments = 0; var versions = 0; var proposals = 0 }

    static func run(in container: ModelContainer,
                    persist: (ModelContext) throws -> Void = { try $0.save() }) throws -> Counts {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard try context.fetch(FetchDescriptor<StoreMaintenance>()).allSatisfy({ $0.key != key }) else { return Counts() }
        do {
            let notes = try context.fetch(FetchDescriptor<NoteItem>())
            // Explicit stored discriminator. Nil content alone is never old.
            let ids = Set(notes.filter { $0.contentFormat == 0 }.map(\.id))
            let removed = notes.filter { ids.contains($0.id) }
            let attachments = try context.fetch(FetchDescriptor<NoteAttachment>()).filter { ids.contains($0.noteID) }
            let versions = try context.fetch(FetchDescriptor<NoteVersion>()).filter { ids.contains($0.noteID) }
            let proposals = try context.fetch(FetchDescriptor<NotePendingEdit>()).filter { ids.contains($0.noteID) }
            _ = try LinkStore.stagePurge(touching: Set(ids.map { AtticItemRef(.note, $0) }), in: context)
            removed.forEach(context.delete); attachments.forEach(context.delete)
            versions.forEach(context.delete); proposals.forEach(context.delete)
            var files = Set(attachments.map(\.id))
            files.formUnion(versions.flatMap(\.attachmentIDs))
            files.formUnion(removed.compactMap(\.deletedAttachmentIDs).flatMap { $0 })
            for bytes in removed.compactMap(\.content) + versions.compactMap(\.content) + proposals.compactMap(\.proposedContent) {
                if let document = NoteContentCodec.decode(bytes).document { files.formUnion(document.attachmentIDs) }
            }
            context.insert(StoreMaintenance(key: key, noteIDs: ids, attachmentIDs: files))
            try persist(context)
            let counts = Counts(notes: removed.count, attachments: attachments.count,
                versions: versions.count, proposals: proposals.count)
            NSLog("Attic old-note removal: notes=%d attachments=%d versions=%d proposals=%d",
                counts.notes, counts.attachments, counts.versions, counts.proposals)
            return counts
        } catch { context.rollback(); throw error }
    }

    /// Roots must belong to this launch's store (runtime supplies them).
    /// No filesystem changes precede the successful database transaction.
    static func cleanup(in container: ModelContainer, recoveryURL: URL?, attachmentRoot: URL?) throws {
        let context = ModelContext(container); context.autosaveEnabled = false
        guard let marker = try context.fetch(FetchDescriptor<StoreMaintenance>()).first(where: { $0.key == key }),
              !marker.filesCleaned else { return }
        let noteIDs = ids(marker.noteIDsRaw)
        var attachmentIDs = ids(marker.attachmentIDsRaw)
        var staged = ids(marker.stagedIDsRaw), retainedStaging = Set<UUID>()
        var stagingKnown = true, recoveryOwnershipKnown = true, targets: [URL] = []
        var recoveryAttachments = Set<UUID>(), emptiedArchives: [URL] = []
        let manager = FileManager.default
        func object(_ url: URL) throws -> [String: Any]? {
            let checked = try safe(url)
            guard manager.fileExists(atPath: checked.path) else { return nil }
            return try JSONSerialization.jsonObject(with: Data(contentsOf: checked)) as? [String: Any]
        }
        func stagedIDs(_ object: [String: Any]) -> Set<UUID>? {
            guard let rows = object["staged"] as? [[String: Any]] else { return nil }
            let values = rows.compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) }
            return values.count == rows.count ? Set(values) : nil
        }
        if let recoveryURL {
            let journal = recoveryURL.deletingLastPathComponent().appendingPathComponent("NoteDrafts", isDirectory: true)
            if manager.fileExists(atPath: journal.path) {
                for file in try manager.contentsOfDirectory(at: try safe(journal), includingPropertiesForKeys: nil)
                    where file.pathExtension == "json" {
                    let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent)
                    if id.map(noteIDs.contains) == true {
                        if let data = try? object(file) {
                            if let owned = stagedIDs(data) { staged.formUnion(owned); attachmentIDs.formUnion(owned) }
                            if let encoded = data["content"] as? String, let bytes = Data(base64Encoded: encoded),
                               let document = NoteContentCodec.decode(bytes).document { attachmentIDs.formUnion(document.attachmentIDs) }
                        }
                        targets.append(file)
                    } else if let snapshot = try? NoteRecoveryMaintenanceSnapshot.read(try safe(file), directory: journal) {
                        retainedStaging.formUnion(snapshot.stagedIDs)
                        recoveryAttachments.formUnion(snapshot.documentIDs.union(snapshot.stagedIDs))
                    } else { stagingKnown = false; recoveryOwnershipKnown = false }
                }
                let quarantine = journal.appendingPathComponent("quarantine", isDirectory: true)
                if manager.fileExists(atPath: quarantine.path) {
                    for archive in try manager.contentsOfDirectory(at: try safe(quarantine), includingPropertiesForKeys: nil) {
                        let files = try manager.contentsOfDirectory(at: try safe(archive), includingPropertiesForKeys: nil)
                        let checkpoints = files.filter {
                            $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
                        }
                        let oldCheckpoints = checkpoints.filter {
                            UUID(uuidString: $0.deletingPathExtension().lastPathComponent).map(noteIDs.contains) == true
                        }
                        // An archive can copy ALL active staging, including another note's.
                        // Only a single identified old checkpoint proves derived text ownership.
                        let oldOnly = checkpoints.count == 1 && oldCheckpoints.count == 1
                        let derived = files.filter { ["readable-note.json", "readable-note.md"].contains($0.lastPathComponent) }
                        var copies = oldOnly ? derived : []
                        let raw = archive.appendingPathComponent("resolved-checkpoint.raw")
                        if oldOnly, manager.fileExists(atPath: raw.path),
                           try Data(contentsOf: safe(raw)) == Data(contentsOf: safe(oldCheckpoints[0])) {
                            copies.append(raw)
                        }
                        // Keep the identifying checkpoint until all proven copies are gone,
                        // so interrupted cleanup can classify them again on retry.
                        targets.append(contentsOf: copies)
                        targets.append(contentsOf: oldCheckpoints)
                        let uncertain = files.filter { file in
                            !oldCheckpoints.contains(file) && !copies.contains(file)
                        }
                        if !uncertain.isEmpty {
                            stagingKnown = false; recoveryOwnershipKnown = false
                        }
                        emptiedArchives.append(archive)
                    }
                }
            }
            if manager.fileExists(atPath: recoveryURL.path) {
                if let data = try? object(recoveryURL) {
                    let note = (data["noteID"] as? String).flatMap(UUID.init(uuidString:))
                    let reserved = (data["reservedNoteID"] as? String).flatMap(UUID.init(uuidString:))
                    let invalid = (data["noteID"] != nil && !(data["noteID"] is NSNull) && note == nil)
                        || (data["reservedNoteID"] != nil && !(data["reservedNoteID"] is NSNull) && reserved == nil)
                    let conflicting = note != nil && reserved != nil && note != reserved
                    if !invalid, !conflicting, let id = note ?? reserved, noteIDs.contains(id) {
                        targets.append(recoveryURL)
                    } else { stagingKnown = false; recoveryOwnershipKnown = false }
                } else { stagingKnown = false; recoveryOwnershipKnown = false }
            }
            // Persist the staging manifest BEFORE deleting its source files,
            // so interrupted cleanup can finish on the next store open.
            marker.stagedIDsRaw = NoteVersion.encodeIDs(Array(staged))
            marker.attachmentIDsRaw = NoteVersion.encodeIDs(Array(attachmentIDs)); try context.save()
            if stagingKnown {
                for id in staged.subtracting(retainedStaging) {
                    targets.append(journal.appendingPathComponent("staged", isDirectory: true).appendingPathComponent(id.uuidString))
                }
            }
        }
        if let attachmentRoot {
            var retained = Set(try context.fetch(FetchDescriptor<NoteAttachment>()).map(\.id))
            retained.formUnion(recoveryAttachments)
            // Unknown/newer ownership conservatively keeps materialized bytes.
            if recoveryOwnershipKnown, let documentIDs = try? NoteDocumentRetentionSnapshot.read(in: context).attachmentIDs() {
                retained.formUnion(documentIDs)
                for id in attachmentIDs.subtracting(retained) {
                    targets.append(attachmentRoot.appendingPathComponent(id.uuidString, isDirectory: true))
                }
            }
        }
        for target in targets {
            let checked = try safe(target)
            if manager.fileExists(atPath: checked.path) { try manager.removeItem(at: checked) }
        }
        for archive in emptiedArchives {
            let checked = try safe(archive)
            if try manager.contentsOfDirectory(atPath: checked.path).isEmpty { try manager.removeItem(at: checked) }
        }
        marker.filesCleaned = true; try context.save()
    }

    private static func ids(_ raw: String) -> Set<UUID> {
        Set(raw.split(separator: " ").compactMap { UUID(uuidString: String($0)) })
    }
    private static func safe(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        guard standardized.resolvingSymlinksInPath().path == standardized.path else {
            throw CocoaError(.fileReadNoPermission)
        }
        return standardized
    }
}
