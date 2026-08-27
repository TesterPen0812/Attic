import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct NoteAttachmentTray: View {
    @ObservedObject var noteStore: NoteStore
    @ObservedObject var noteDraft: NoteDraftController

    @State private var isImporterPresented = false
    @State private var isDropTargeted = false

    private var attachments: [NoteAttachment] {
        guard let noteID = noteDraft.activeNoteID else { return [] }
        return noteStore.attachments(for: noteID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Label("Attachments", systemImage: "paperclip")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add file", systemImage: "plus") {
                    isImporterPresented = true
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityIdentifier("add-note-attachment")
            }

            if attachments.isEmpty {
                dropTarget
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 4) {
                        ForEach(attachments) { attachment in
                            NoteAttachmentRow(
                                noteStore: noteStore,
                                attachment: attachment
                            )
                        }
                    }
                }
                .frame(maxHeight: 116)
                .scrollIndicators(.never)
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
                    acceptDrop(providers)
                }
            }

            if case let .importing(completed, total) = noteStore.attachmentImportState {
                ProgressView(value: Double(completed), total: Double(max(total, 1)))
                    .controlSize(.small)
                    .accessibilityLabel("Importing attachments")
            } else if case let .failed(message) = noteStore.attachmentImportState {
                Text(message)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 3)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            importURLs(urls)
        }
    }

    private var dropTarget: some View {
        Text("Drop files here")
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(
                Color.accentColor.opacity(isDropTargeted ? 0.14 : 0.06),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        Color.accentColor.opacity(isDropTargeted ? 0.8 : 0.25),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
                acceptDrop(providers)
            }
            .accessibilityLabel("Drop files here to attach them to the note")
            .accessibilityIdentifier("note-attachment-drop-target")
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        let retainedProviders = providers
        Task { @MainActor in
            let urls = await Self.loadFileURLs(from: retainedProviders)
            importURLs(urls)
        }
        return !providers.isEmpty
    }

    private func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty, noteDraft.flush() else { return }
        let previousNoteID = noteDraft.activeNoteID
        Task { @MainActor in
            let noteID = await noteStore.importAttachments(from: urls, noteID: previousNoteID)
            if previousNoteID == nil, let noteID {
                noteDraft.adoptAttachmentOnlyNote(noteID)
            }
        }
    }

    private static func loadFileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await loadFileURL(from: provider) {
                urls.append(url)
            }
        }
        return urls
    }

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                    return
                }
                if let url = item as? NSURL {
                    continuation.resume(returning: url as URL)
                    return
                }
                if let data = item as? Data,
                   let string = String(data: data, encoding: .utf8),
                   let url = URL(string: string) {
                    continuation.resume(returning: url)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }
}

private struct NoteAttachmentRow: View {
    @ObservedObject var noteStore: NoteStore
    let attachment: NoteAttachment
    @State private var isConfirmingRemoval = false

    var body: some View {
        HStack(spacing: 7) {
            AttachmentThumbnail(noteStore: noteStore, attachment: attachment)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.originalFilename)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .lineLimit(1)
                Text("\(attachment.contentType.preferredMIMEType ?? "File") · \(ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file))")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Preview", systemImage: "eye") {
                NoteAttachmentActions.preview(store: noteStore, attachment: attachment)
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .help("Preview attachment")

            Button("Open", systemImage: "arrow.up.forward.square") {
                NoteAttachmentActions.open(store: noteStore, attachment: attachment)
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .disabled(!NoteAttachmentActions.isSafeToOpen(attachment))
            .help("Open attachment")

            Button("Export copy", systemImage: "square.and.arrow.down") {
                NoteAttachmentActions.export(store: noteStore, attachment: attachment)
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .help("Export a copy")

            Button("Remove", systemImage: "xmark.circle.fill") {
                isConfirmingRemoval = true
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
            .help("Remove attachment")
        }
        .padding(.vertical, 2)
        .confirmationDialog(
            "Remove attachment?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                _ = noteStore.removeAttachment(attachment)
            }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("note-attachment-\(attachment.id.uuidString)")
    }
}

private struct AttachmentThumbnail: View {
    @ObservedObject var noteStore: NoteStore
    let attachment: NoteAttachment
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: attachment.isImage ? "photo" : "doc")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .task(id: attachment.id) {
            guard attachment.isImage else { return }
            guard let url = await noteStore.materializedURL(for: attachment) else { return }
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 60, height: 60),
                scale: NSScreen.main?.backingScaleFactor ?? 2,
                representationTypes: .thumbnail
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                guard let representation else { return }
                DispatchQueue.main.async {
                    image = representation.nsImage
                }
            }
        }
    }
}
