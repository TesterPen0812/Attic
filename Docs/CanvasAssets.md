# Canvas image assets — verified local macOS contract

Canvas imports canonical application-owned bytes into the local SwiftData store. A file URL or file-promise delivery is only an input channel: the importer enters security-scoped access when necessary, reads while access is active, and does not persist the source path or bookmark.

## Import policy

- Source reads are limited to 64 MiB; larger inputs are rejected before decode.
- ImageIO applies orientation and prepares canonical bytes away from the main actor.
- The longest decoded edge is limited to 4,096 pixels.
- Canonical output is PNG when alpha is required and JPEG otherwise.
- Canonical encoded output is limited to 8 MiB; bounded dimension/quality retries are used before rejection.
- Unsupported or corrupt import input produces a failed item and no image row.
- Batch preparation is bounded to two concurrent items, supports cancellation, preserves source order, and cleans task-owned temporary delivery directories.
- Every batch captures a page UUID and board generation before asynchronous work. The store revalidates that immutable target and persists accepted items in one transaction.

Drag/drop advertises copy only for supported image/file representations. File-promise delivery errors remain item-scoped. Stable user-visible progress, per-item retry/removal actions, and live Finder/File Provider timing still require completion and installed verification.

## Local storage model

`CanvasImageItem.encodedData` is a SwiftData external-storage attribute. Each row also records its logical canvas UUID, pixel dimensions, transform, z-order, board generation, mutation version, timestamps, and `tombstoned` deletion state.

Logical UUIDs are duplicate-safe at the application layer. Refresh selects one deterministic visible winner; mutation, restore, layer movement, clear, and deletion apply to every physical replica for that logical UUID. Reconciliation does not delete an arbitrary duplicate.

`ATTIC_LOCAL_ONLY` builds do not create Canvas CloudKit observers, iCloud status work, export/import activity assertions, or timeout tasks. External storage is a local persistence choice here; it is not a claim of active CloudKit asset synchronization. No Production schema or Mac/iPhone delivery is part of the current verification boundary.

## Runtime decode and rendering

Encoded bytes remain durable. Decoded `CGImage` values are kept in an `NSCache` with a 256 MiB total-cost limit and a 48-image count limit. Decoding runs in utility-priority detached work, and drawing culls objects outside an expanded world viewport. Switching pages clears the native image cache.

Current limitations are explicit:

- the surface can request decode for all supplied page images rather than a bounded visible-first queue;
- cancellation prevents a completed decode from being published, but ImageIO work itself is not cooperatively interrupted once running;
- failed decode results are not memoized, so an invalid payload can be retried;
- transform-only persistence avoids rewriting encoded bytes, but refresh still compares the full encoded `Data` on the main actor to validate cache identity;
- the count/cost-bounded decode cache does not make Undo history byte-bounded.

Those resource and recovery gaps remain tracked under C-04, C-07, and C-10.

## Verification boundary

Local unit tests can establish import limits, immutable target checks, duplicate-safe persistence, ordering, cancellation outcomes, and cache math. Signed installed tests are still required for real file promises, large batches, progress/recovery UI, memory growth, decode latency, cancellation latency, and disk activity. Physical trackpad behavior and any deferred mobile/Cloud workflow are outside what these tests prove.
