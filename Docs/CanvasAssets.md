# Canvas image assets and CloudKit limits

Canvas imports an image as canonical application-owned bytes. A file URL is only an input channel: the importer enters a security-scoped resource when necessary, reads the bytes while access is active, and never persists the source path or bookmark.

## Import policy

- The source read budget is 64 MiB. Larger inputs are rejected before image decode.
- ImageIO decodes and applies orientation away from the main actor.
- The longest decoded edge is limited to 4,096 pixels.
- The canonical payload is PNG when alpha is required and JPEG otherwise.
- The canonical encoded payload is limited to 8 MiB. Encoding retries with bounded dimensions/quality; an image that cannot meet the limit is rejected.
- Corrupt and unsupported payloads produce a user-visible error and no model row.

These are application limits, not statements of CloudKit's absolute service limits. They intentionally leave headroom for record metadata, mirroring overhead, and future schema growth.

## Storage and synchronization model

`CanvasImageItem.encodedData` is a SwiftData external-storage attribute. SwiftData/Core Data can mirror that value as a CloudKit asset rather than forcing multi-megabyte data into an inline field. Each image row also stores its logical canvas ID, pixel dimensions, transform, z-order, generation, mutation version, timestamps, and the persisted deletion field `tombstoned`.

CloudKit cannot enforce the app UUID as a unique key. Multiple physical rows may therefore represent one logical board or image. Refresh deterministically selects a presentation winner; mutations, restores, clear operations, and deletion update every physical replica. Rows are tombstoned instead of being arbitrarily deleted during reconciliation.

The model remains additive and CloudKit-compatible: every persisted property has a default or is optional, and no SwiftData unique constraint is used. Development schema initialization is versioned, but this implementation does **not** deploy a Production schema. A release must not depend on the new record types until the schema has been reviewed and deliberately deployed through the normal release process.

## Runtime memory and rendering

Encoded bytes remain the durable source. Decoded `CGImage` values live in a bounded cache with a 256 MiB total-cost limit and a 48-image count limit. Decode occurs in a detached utility-priority task. Transform-only changes retain an ephemeral content token, allowing the decoded bitmap to be reused without comparing the encoded `Data` on the main actor. Off-screen images are culled before drawing, pending decode tasks are cancelled when images leave the active canvas, and switching canvases clears the native cache.

## Verification boundary

In-memory and simulator tests can prove model compatibility, replica semantics, coordinate transforms, persistence, and buildability. They cannot prove Production Mac-to-iPhone or iPhone-to-Mac delivery. That still requires distributed TestFlight builds on a real Mac and real iPhone, signed into the same iCloud account, following the Live Sync Contract in `AGENTS.md`.
