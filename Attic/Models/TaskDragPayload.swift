import AppKit
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// One attachment dragged out of a gallery. The receiver gets its own copy of
/// the verified private file, produced only when the drop is accepted; the
/// private copy is never offered in place and nothing is copied while the
/// gallery lays out or resizes.
///
/// The file is promised under the attachment's recorded type (for example
/// `public.png`), not a static `public.data`, so receivers that accept only
/// images, or only one image format, still take it; generic file receivers
/// match through type conformance.
struct TaskAttachmentDragItem: Sendable {
    let reference: TaskImageReference
    let files: TaskImageFiles

    var contentType: UTType {
        reference.contentType.conforms(to: .data) ? reference.contentType : .data
    }

    /// The name a receiver should give its copy. `NSItemProvider` appends
    /// the representation type's preferred extension to `suggestedName`
    /// itself, so a name that already carries that extension arrives as
    /// "Picture.png.png"; the extension is stripped exactly when the type
    /// would add the same one back.
    var suggestedName: String {
        let name = reference.filename
        let extensionText = (name as NSString).pathExtension
        guard !extensionText.isEmpty,
              let preferred = contentType.preferredFilenameExtension,
              preferred.caseInsensitiveCompare(extensionText) == .orderedSame
                || contentType.tags[.filenameExtension]?.contains(where: {
                    $0.caseInsensitiveCompare(extensionText) == .orderedSame
                }) == true else { return name }
        return (name as NSString).deletingPathExtension
    }

    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = suggestedName
        let item = self
        // No `.openInPlace`: receivers are handed a copy of the file.
        provider.registerFileRepresentation(
            forTypeIdentifier: contentType.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            Task {
                do {
                    guard let url = try await item.files.verifiedURL(for: item.reference) else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        // Lets Attic's own task drop targets recognize and refuse the card,
        // so releasing it over its panel never re-imports it. Registered after
        // the file (lower fidelity) and visible only to this process.
        provider.registerDataRepresentation(
            forTypeIdentifier: TaskDropContent.attachmentCardType.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(Data(item.reference.id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }
}

struct TaskDragPayload: Codable, Sendable, Transferable {
    static let internalTaskType = UTType(
        exportedAs: "com.taha.attic.task-id"
    )

    let taskID: UUID?
    let title: String
    var imageReferences: [TaskImageReference]?

    init(taskID: UUID? = nil, title: String, imageReferences: [TaskImageReference] = []) {
        self.taskID = taskID
        self.title = title
        self.imageReferences = imageReferences.isEmpty ? nil : imageReferences
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: internalTaskType)
        FileRepresentation(exportedContentType: .folder) { payload in
            let folder = try await TaskImageFiles.shared.export(title: payload.title, references: payload.imageReferences ?? [])
            return SentTransferredFile(folder)
        }
        .exportingCondition { !($0.imageReferences ?? []).isEmpty }
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
