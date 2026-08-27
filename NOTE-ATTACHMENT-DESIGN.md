# Note Attachment Design

## Scope and invariants

Attachments are an additive Notes feature. They do not change Attic's bundle identifiers, entitlements, CloudKit container or environment selection, persistent-store locations, remote-change observers, CloudKit-event observers, or existing production records.

A dropped file becomes independent of its Finder source. Attic stores the bytes in its SwiftData/CloudKit model and materializes an app-owned file under Application Support for preview and export. The original absolute path is never persisted. Moving, replacing, or deleting the source after import cannot break the attachment.

The implementation keeps the repository's existing replica rules: logical UUIDs are not database-unique, presentation deduplicates physical replicas, and every mutation or deletion addresses every matching physical replica.

## Persisted schema

Add one CloudKit-compatible SwiftData model and register it in the existing macOS, iOS, test, and Development-schema model lists:

```swift
@Model
final class NoteAttachment {
    var id: UUID = UUID()
    var noteID: UUID = UUID()
    var originalFilename: String = ""
    var contentTypeIdentifier: String = UTType.data.identifier
    var byteCount: Int64 = 0
    var sortIndex: Int64 = 0
    var contentDigest: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    @Attribute(.externalStorage) var payload: Data? = nil
}
```

There is deliberately no `@Attribute(.unique)` or `#Unique`. There is also no SwiftData relationship to `NoteItem`; `noteID` is a logical foreign key. This avoids introducing a required relationship into the existing CloudKit schema, keeps additive migration straightforward, and makes duplicate-replica handling explicit.

All nonoptional fields have defaults. The payload is optional for CloudKit schema compatibility, but a committed visible attachment is valid only when its payload is present and its digest/size match. A missing or invalid payload is surfaced as an unavailable attachment; it is never silently discarded.

`originalFilename` is display/export metadata only. Files with identical names remain distinct because storage identity is `id` plus `contentDigest`. Presentation order is `sortIndex`, then `createdAt`, then `id`; a dropped batch receives monotonically increasing sort indices in Finder order.

Apple documents that SwiftData `externalStorage` keeps binary data outside the database row, and that Core Data's CloudKit mirroring can serialize binary data as a `CKAsset`. CloudKit excludes assets from the 1 MB record-body limit and stores filename metadata separately from asset bytes. The app treats SwiftData as the owner of that representation and never depends on private CloudKit field names or a fixed framework-controlled binary-to-asset threshold.

## Limits

Attic enforces these application limits before copying:

- 15 MiB per attachment.
- 100 MiB total attachments per note.
- 20 attachments per note.
- 512 UTF-8 bytes for the display filename; longer names are safely truncated while preserving a usable extension.

The 15 MiB ceiling is conservative: Apple's CloudKit Web Services reference documents a 15 MB asset-upload maximum, while native SwiftData/Core Data mirroring remains framework-managed. The app limit also bounds memory mapping, sync cost, rollback work, thumbnail generation, and denial-of-service exposure. It is not a claim that every native CloudKit path has the same hard maximum.

Only regular files are accepted. Directories, packages, symbolic links, sockets, devices, and other special filesystem objects are rejected. Zero-byte regular files are allowed. Filename and UTI values are untrusted metadata and are never used to construct an unchecked path.

## App-owned file layout

The synchronized `payload` is the cross-device source of truth. Each device materializes a private file at a deterministic descendant of:

```text
Application Support/Attic/Attachments/v1/<attachment-id>/<sha256>/<sanitized-name>
```

A path is constructed only from validated model values, standardized, and checked to remain below the attachment root. The SHA-256 digest both separates divergent replicas and verifies materialization. Thumbnail files, when cached, live under a separate versioned cache root and are always regenerable.

The materialized file is not a bookmark to the source and does not require long-term security-scoped access. If it is missing after relaunch or arrives through CloudKit, Attic recreates it atomically from `payload` before preview, open, or export.

## Import transaction

A serial import coordinator handles one dropped batch at a time and publishes per-file progress and a batch error. Input order is preserved.

1. Preflight every URL and the note-level limits. Start security-scoped access only when the URL grants it, and always balance a successful start with `stopAccessingSecurityScopedResource()` in `defer`.
2. Use `NSFileCoordinator` for a coordinated read. Do not resolve symbolic links or execute/open the source.
3. Stream each source into a uniquely named staging file inside Attic's Application Support volume while counting bytes and computing SHA-256. Abort immediately on limit overflow, short read, mutation, or I/O error.
4. Atomically move each completed staging file into its deterministic final directory. Duplicate display names do not collide because the UUID/digest directories differ.
5. In one short-lived `ModelContext`, insert all `NoteAttachment` rows and, for an attachment-only new draft, insert the blank `NoteItem` with the draft's predetermined logical UUID. Load payloads from the staged app-owned files using bounded/mapped `Data`, then save once.
6. On any failure before the save, remove every staging/final file created by the batch. On save failure, roll back the context and remove those files. On success, refresh `NoteStore` and the attachment store through fresh contexts.

The filesystem and SQLite cannot form one distributed transaction. The compensating rollback above covers reported failures; a process crash can leave only an unreferenced app-owned file, which deterministic orphan cleanup removes on the next reconciliation. A database row is never committed with a source path as its only locator.

Dropping an attachment into a new blank draft is allowed and creates an attachment-only note. An entirely blank draft with no attachments still creates no note.

## Read, preview, open, export, and remove

Before use, Attic verifies or rematerializes the app-owned file from `payload`.

- Images use Quick Look Thumbnailing for thumbnails; other files show the system file icon plus display name and formatted size.
- Preview uses Quick Look against the app-owned file.
- Open uses the app-owned file, never the source. It is disabled for applications, executables, scripts, installer packages, disk images, packages, and unknown types that may execute. Those files remain previewable when Quick Look supports them and always remain exportable.
- Export uses a system destination picker and copies to a same-volume temporary/replacement location before an atomic replacement. Export never moves the app-owned file.
- Remove fetches and deletes every physical `NoteAttachment` replica with the logical attachment UUID in one save. Only after that save succeeds are all corresponding app-owned UUID/digest directories removed. A failed save leaves bytes intact.

Deleting a note fetches every physical `NoteItem` replica and every attachment replica whose `noteID` matches, deletes them in the same context save, then removes all app-owned directories for that note's attachments. This extends the current duplicate-replica safety rather than relying on a cascade relationship.

## Refresh, concurrency, and cleanup

Attachment mutations run through one main-actor store plus a serial filesystem actor. UI state is transient; SwiftData contains only committed attachments.

After remote-store notifications and completed CloudKit imports, the attachment store replaces its long-lived `ModelContext`, deduplicates logical attachments for presentation, and then reconciles files. Reconciliation:

1. builds the expected UUID/digest set from all physical attachment rows, not only visible winners;
2. rematerializes a requested visible attachment whose valid payload exists but file is missing;
3. removes transaction staging directories older than 24 hours;
4. removes versioned attachment directories not referenced by any physical row; and
5. removes obsolete digest directories only when no physical replica references them.

Cleanup is confined to the canonical app-owned root and is idempotent. It never deletes a model row because a local materialization is absent. This prevents a temporarily unavailable CloudKit payload from becoming data loss.

## UI contract

On macOS, the Notes editor has one bounded attachment tray and a clear drop target that accepts multiple Finder file URLs. Async progress does not change editor identity or steal text focus. Each row/card exposes Preview, safe Open, Export Copy, and Remove with accessible labels, keyboard reachability, filename, type, size, progress, and error status. The attachment tray scrolls within a bounded height so thumbnail completion does not repeatedly resize the panel.

On iPhone, synchronized attachments use the same ordering and metadata, support Quick Look preview, export/share copy, and removal. A system file importer may feed the same transaction path; its security-scoped URLs follow the same balancing rules.

## Migration and project generation

The migration is additive: existing `NoteItem` records require no mutation and naturally have zero attachments. `NoteAttachment.self` is added to the existing schema arrays and Development schema initializer only. No Production schema deployment occurs in this branch.

New shared model/store/repository files are added to `shared_mobile_sources` where required. `Attic.xcodeproj` is regenerated only through `Scripts/generate_project.rb`, and `Scripts/verify_project_generation.rb` must report a repeatable current project.

## Required regression evidence

Automated tests cover: duplicate filenames; Finder-order preservation; attachment-only notes; source deletion after import; size/count/aggregate limits; directory/symlink rejection; balanced security scope; mid-stream and persistence rollback; stale-context refresh; duplicate physical rows; removal/deletion of every replica; missing-file rematerialization; deterministic orphan cleanup; export without moving stored bytes; unsafe-open denial; and non-Notes Task/Backlog behavior.

Local evidence still required before release includes Xcode compilation, macOS Finder multi-drop, focus and panel-size recordings, relaunch/rematerialization, Quick Look and export panels, iPhone presentation, Development CloudKit schema inspection, and real-device bidirectional sync/conflict/deletion scenarios. None of those are inferred from source.

## Apple references

- SwiftData external storage: https://developer.apple.com/documentation/swiftdata/schema/attribute/option/externalstorage
- SwiftData model configuration: https://developer.apple.com/documentation/swiftdata/modelconfiguration
- Core Data/CloudKit binary assets: https://developer.apple.com/documentation/coredata/reading-cloudkit-records-for-core-data
- `CKAsset`: https://developer.apple.com/documentation/cloudkit/ckasset
- CloudKit record/request limits: https://developer.apple.com/documentation/cloudkit/ckrecord and https://developer.apple.com/documentation/cloudkit/ckerror/limitexceeded
- CloudKit Web Services asset upload: https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/UploadAssets.html
- Security-scoped URLs: https://developer.apple.com/documentation/foundation/nsurl
- File coordination for upload-style reads: https://developer.apple.com/documentation/foundation/nsfilecoordinator/readingoptions/foruploading
- Atomic replacement: https://developer.apple.com/documentation/foundation/filemanager/replaceitemat(_:withitemat:backupitemname:options:)
- Quick Look: https://developer.apple.com/documentation/quicklook
- Quick Look Thumbnailing: https://developer.apple.com/documentation/quicklookthumbnailing/qlthumbnailgenerator
- Uniform Type Identifiers: https://developer.apple.com/documentation/uniformtypeidentifiers
