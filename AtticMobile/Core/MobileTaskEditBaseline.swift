import Foundation

struct MobileTaskEditPatch: Equatable {
    let title: String?
    let priority: TaskPriority?
    let status: TaskStatus?
}

struct MobileTaskEditBaseline: Equatable {
    let title: String
    let priority: TaskPriority
    let status: TaskStatus

    func patch(
        title editedTitle: String,
        priority editedPriority: TaskPriority,
        status editedStatus: TaskStatus
    ) -> MobileTaskEditPatch {
        MobileTaskEditPatch(
            title: editedTitle == title ? nil : editedTitle,
            priority: editedPriority == priority ? nil : editedPriority,
            status: editedStatus == status ? nil : editedStatus
        )
    }
}
