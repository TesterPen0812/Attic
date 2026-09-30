import AppKit

/// An action drawn on an object in a failure state, and offered in its menu
/// and to VoiceOver (UX plan § 3.5): the same command either way.
struct NoteObjectInlineAction: Equatable {
    let title: String
    let command: NoteObjectCommand
}

extension NoteObjectState {
    /// The actions each failure shows on its object, in this order:
    /// Import failed: Retry · Remove. Preview unavailable: Quick Look ·
    /// Export Copy… · Remove (Retry Preview is in the menu). Original
    /// missing: Locate… · Remove. A ready object shows none.
    var inlineActions: [NoteObjectInlineAction] {
        switch self {
        case .ready: []
        case .importFailed:
            [.init(title: String(localized: "Retry"), command: .retry),
             .init(title: String(localized: "Remove"), command: .delete)]
        case .previewUnavailable:
            [.init(title: String(localized: "Quick Look"), command: .quickLook),
             .init(title: String(localized: "Export Copy…"), command: .exportCopy(nil)),
             .init(title: String(localized: "Remove"), command: .delete)]
        case .originalMissing:
            [.init(title: String(localized: "Locate…"), command: .locate),
             .init(title: String(localized: "Remove"), command: .delete)]
        }
    }

    /// The short message the object shows.
    var message: String? {
        switch self {
        case .ready: nil
        case .importFailed: String(localized: "Import failed")
        case .previewUnavailable: String(localized: "Preview unavailable")
        case .originalMissing: String(localized: "Original missing")
        }
    }
}

@MainActor
extension NoteEditorEngine {
    /// The failure's actions this object can run now (a read-only note
    /// offers no Retry, Locate or Remove).
    func inlineActions(for object: NoteObjectAttachment) -> [NoteObjectInlineAction] {
        let state = objectState(for: object)
        return state.inlineActions.filter { validate($0.command, object: object, state: state).enabled }
    }

    /// What a file card, or an image that cannot be shown, draws. nil for a
    /// ready image (its picture is its face) and for other objects.
    func objectFace(for object: NoteObjectAttachment) -> AtticNoteObjectFace? {
        let state = objectState(for: object)
        let actions = inlineActions(for: object).map(\.title)
        switch object {
        case let file as NoteFileAttachment:
            let size = ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file)
            return AtticNoteObjectFace(kind: .file, name: file.filename, detail: state.message ?? size,
                                       tone: Self.tone(state),
                                       systemImage: Self.glyph(state) ?? AtticNoteObjectFace.systemImage(
                                           forContentType: file.contentTypeIdentifier),
                                       actions: actions)
        case let image as NoteImageAttachment:
            guard state != .ready || image.isMissing else { return nil }
            return AtticNoteObjectFace(kind: .image, name: image.filename,
                                       detail: state.message ?? String(localized: "Image unavailable"),
                                       tone: Self.tone(state), systemImage: Self.glyph(state) ?? "photo",
                                       actions: actions)
        default:
            return nil
        }
    }

    /// The width a file card is drawn at: the column, at most 300.
    var objectColumnWidth: CGFloat {
        let padding = textView?.textContainer?.lineFragmentPadding ?? 0
        return max(40, (textView?.textContainer?.size.width ?? 320) - padding * 2)
    }

    private static func tone(_ state: NoteObjectState) -> AtticNoteObjectFace.Tone {
        switch state {
        case .ready: .normal
        case .previewUnavailable: .quiet
        case .importFailed, .originalMissing: .failure
        }
    }

    private static func glyph(_ state: NoteObjectState) -> String? {
        switch state {
        case .ready: nil
        case .previewUnavailable: "eye.slash"
        case .importFailed, .originalMissing: "exclamationmark.circle"
        }
    }
}
