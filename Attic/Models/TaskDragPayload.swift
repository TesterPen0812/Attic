import AppKit
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct TaskDragPayload: Codable, Sendable, Transferable {
    static let internalTaskType = UTType(
        exportedAs: "com.emanueledipietro.attic.task-id"
    )

    let taskID: UUID?
    let title: String

    init(taskID: UUID? = nil, title: String) {
        self.taskID = taskID
        self.title = title
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: internalTaskType)
        ProxyRepresentation(exporting: \.title)
    }

    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        if let taskID {
            provider.registerDataRepresentation(
                forTypeIdentifier: Self.internalTaskType.identifier,
                visibility: .ownProcess
            ) { completion in
                completion(Data(taskID.uuidString.utf8), nil)
                return nil
            }
        }

        let plainTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.utf8PlainText.identifier,
            visibility: .all
        ) { completion in
            completion(Data(plainTitle.utf8), nil)
            return nil
        }
        return provider
    }

    @discardableResult
    static func loadTaskID(
        from providers: [NSItemProvider],
        completion: @escaping @MainActor @Sendable (UUID) -> Void
    ) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(internalTaskType.identifier)
        }) else { return false }

        provider.loadDataRepresentation(
            forTypeIdentifier: internalTaskType.identifier
        ) { data, _ in
            guard let data,
                  let rawValue = String(data: data, encoding: .utf8),
                  let taskID = UUID(uuidString: rawValue) else { return }
            Task { @MainActor in completion(taskID) }
        }
        return true
    }
}
