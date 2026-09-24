import Foundation
import SwiftData

@Model
final class TaskItem {
    // CloudKit can't enforce SwiftData uniqueness. UUID generation plus the
    // TaskStore refresh deduplication keep the app-level identity stable.
    var id: UUID = UUID()
    var title: String = ""
    var statusRaw: String = TaskStatus.todo.rawValue
    var priorityRaw: String = TaskPriority.none.rawValue
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var completedAt: Date? = nil
    var manualOrder: Int64? = nil
    /// A scalar, optional link keeps existing local stores compatible and
    /// avoids SwiftData relationship ownership across duplicate UUID replicas.
    var parentID: UUID? = nil
    /// Small file references only; image and file bytes live in the private
    /// local attachment directory and are never decoded by task-list queries.
    /// The stored name predates general files and stays for compatibility.
    var imageReferencesData: Data? = nil
    /// Soft deletion (Recently Deleted). A deleted task keeps every field,
    /// its subtasks and its files; it is only hidden until it is restored or
    /// purged 30 days later.
    var deletedAt: Date? = nil
    /// The task whose deletion hid this row: its own id, or its parent's when
    /// the whole family was deleted together. Restoring that id brings back
    /// exactly the rows one delete hid, never a subtask deleted on its own.
    var deletionRootID: UUID? = nil
    /// Set when the daily cleanup moves a finished task into the Done log.
    /// The row is kept indefinitely; today's list simply no longer shows it.
    var doneLoggedAt: Date? = nil
    /// Normalised tags (see `AtticTag`), space-separated and sorted. A plain
    /// string keeps the model CloudKit-compatible and duplicate-safe.
    var tagsRaw: String = ""
    /// A floating calendar day (`yyyy-MM-dd`, see `DueDay`), so a due date
    /// never moves when the Mac changes time zone.
    var dueDayRaw: String? = nil

    /// Images and general files in one ordered list, parent-owned. Decoded
    /// once per stored payload: SwiftUI reads this several times per row body,
    /// so the last decode is kept beside the bytes it came from and reused
    /// until the stored data changes (any replica write replaces the data).
    var attachments: [TaskImageReference] {
        guard let imageReferencesData, !imageReferencesData.isEmpty else { return [] }
        if let cached = decodedAttachments, cached.data == imageReferencesData {
            return cached.references
        }
        let references = (try? JSONDecoder().decode([TaskImageReference].self, from: imageReferencesData)) ?? []
        decodedAttachments = DecodedAttachments(data: imageReferencesData, references: references)
        return references
    }

    /// Memo for `attachments`; never persisted.
    @Transient private var decodedAttachments: DecodedAttachments? = nil

    private struct DecodedAttachments {
        let data: Data
        let references: [TaskImageReference]
    }

    init(
        id: UUID = UUID(),
        title: String,
        status: TaskStatus = .todo,
        priority: TaskPriority = .none,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        completedAt: Date? = nil,
        manualOrder: Int64? = nil,
        parentID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        statusRaw = status.rawValue
        priorityRaw = priority.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.completedAt = completedAt
        self.manualOrder = manualOrder
        self.parentID = parentID
    }

    var status: TaskStatus {
        get { TaskStatus(rawValue: statusRaw) ?? .todo }
        set { statusRaw = newValue.rawValue }
    }

    var priority: TaskPriority {
        get { TaskPriority(rawValue: priorityRaw) ?? .none }
        set { priorityRaw = newValue.rawValue }
    }

    var tags: [String] {
        get { AtticTag.decode(tagsRaw) }
        set { tagsRaw = AtticTag.encode(newValue) }
    }

    var dueDay: DueDay? {
        get { dueDayRaw.flatMap(DueDay.init(rawValue:)) }
        set { dueDayRaw = newValue?.rawValue }
    }

    var isSoftDeleted: Bool { deletedAt != nil }
    var isInDoneLog: Bool { doneLoggedAt != nil }
}
