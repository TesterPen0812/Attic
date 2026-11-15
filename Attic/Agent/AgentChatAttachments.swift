import Combine
import Foundation
import UniformTypeIdentifiers

/// Something added with the composer's +, shown as a chip until the message goes.
enum AgentChatAttachment: Identifiable, Equatable {
    case item(AgentTarget)
    case file(AgentFileAttachment, id: UUID)

    var id: String {
        switch self {
        case let .item(target): "item:\(target.page.rawValue):\(target.itemID?.uuidString ?? target.title ?? "")"
        case let .file(_, id): "file:\(id.uuidString)"
        }
    }

    var name: String {
        switch self {
        case let .item(target): target.title.flatMap { $0.isEmpty ? nil : $0 } ?? target.page.rawValue.capitalized
        case let .file(file, _): file.name
        }
    }
}

/// File…: text files only, read once, whole, when picked. The open panel's
/// grant covers that one file; Attic keeps its name and text, never its URL
/// or a bookmark, so nothing outlives the read.
enum AgentChatFiles {
    /// 100 KB: a long document's worth of text, small enough to go with a message.
    static let maxBytes = 100 * 1024

    struct Refusal: Error, Equatable {
        let message: String
        static let notText = Refusal(message: String(localized: "Only text files can be added."))
        static let tooLarge = Refusal(message: String(localized: "Only files up to 100 KB can be added."))
        static let unreadable = Refusal(message: String(localized: "That file could not be read."))
    }

    /// The types the open panel offers: plain text and source of every kind.
    static let types: [UTType] = [.text]

    static func read(_ url: URL) -> Result<AgentFileAttachment, Refusal> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile ?? false else { return .failure(.unreadable) }
        if let type = values?.contentType, !type.conforms(to: .text) { return .failure(.notText) }
        if let size = values?.fileSize, size > maxBytes { return .failure(.tooLarge) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .failure(.unreadable) }
        defer { try? handle.close() }
        // One byte past the cap tells a file that grew since its size was read.
        let data: Data
        do { data = try handle.read(upToCount: maxBytes + 1) ?? Data() } catch { return .failure(.unreadable) }
        guard data.count <= maxBytes else { return .failure(.tooLarge) }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return .failure(.notText) }
        return .success(AgentFileAttachment(name: url.lastPathComponent, text: text))
    }
}

extension AgentChatModel {
    /// The composer's agent menu and Settings' Agent row are one setting:
    /// a change in either shows in the other.
    func bindAgent(to settings: AppSettings) -> AnyCancellable {
        agent = settings.inAppAgentBackend
        agentChanged = { [weak settings] backend in
            if settings?.inAppAgentBackend != backend { settings?.inAppAgentBackend = backend }
        }
        return settings.$inAppAgentBackend.removeDuplicates().sink { [weak self] backend in
            if self?.agent != backend { self?.agent = backend }
        }
    }
}

extension AgentBackendDiscovery {
    /// What Settings says about an agent's status, or nil when it is ready.
    static func reason(_ status: String?) -> String? {
        switch status {
        case "ready": nil
        case "missing": String(localized: "Not installed")
        case "signedOut": String(localized: "Sign in")
        case "update": String(localized: "Update needed")
        case "timedOut": String(localized: "Check timed out")
        default: String(localized: "Unavailable")
        }
    }
}
