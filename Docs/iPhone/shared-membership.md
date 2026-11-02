# Stage 2 · shared local persistence

Use the same Swift files on both platforms. For the new iOS target, replace the dormant target's `shared_mobile_sources` list with the following entries (paths relative to `Attic/`, as expected by `Scripts/generate_project.rb`). Keep the Mac target's existing source membership. This list is the persistence/domain core, not the phone app entry point or its UI.

```text
Services/PersistenceController.swift
Models/AtticItem.swift
Models/AtticTag.swift
Models/DueDay.swift
Models/ItemLink.swift
Models/NoteAttachment.swift
Models/NoteItem.swift
Models/NoteTextReplacement.swift
Models/NoteVersion.swift
Models/OperationReceipt.swift
Models/TagColour.swift
Models/TaskImageReference.swift
Models/TaskItem.swift
Models/TaskTypes.swift
DesignSystem/Tokens/AtticTagHue.swift
Draw/DrawRecords.swift
Draw/DrawTypes.swift
Notes/Format/NoteContentCodec.swift
Notes/Format/NoteDocument.swift
Notes/Format/NoteJSON.swift
Notes/Format/NoteTable.swift
Notes/Format/NoteTextExport.swift
Notes/Format/NoteTableText.swift
Notes/Format/NoteMarkdownExport.swift
Notes/Format/NoteTableAgent.swift
```

`TaskItem` uses task status/priority, floating due days, tags and attachment references. `TaskImageReference` uses the file-reference value in `NoteAttachment.swift`; its Mac private-file manager is not part of the mobile core. `ItemLink` uses `AtticItemRef`. `TagColour` uses the stored hue keys; Mac menu, swatch and Undo routing are not required. `NoteVersion.swift` supplies both history and proposals and uses `NoteTextReplacement` for exact text comparison. `OperationReceipt.swift` supplies the association and deletion-preservation types; inclusion of a source file is not registration of every entity in that file. Draw records use `DrawTypes` and `DrawCodec` (in `DrawRecords.swift`).

The note constructor uses the native codec and `NoteTextExport`. The format graph includes tables/JSON and plain-text projection. `NoteTextExport.swift` also contains the agent parser, which uses `NoteTableAgent`; `NoteTableText` uses the escape and inline helpers in `NoteMarkdownExport`. These files need no Markdown package product. `NoteMarkdownImport.swift` is not part of this graph. Frameworks: Foundation, SwiftData, CryptoKit and UniformTypeIdentifiers on iOS. iOS 26 minimum; local-only app and test configurations; no cloud or push entitlements.

## Integration boundary

Do not carry forward `Services/TaskStore.swift`, `Services/NoteStore.swift`, `Services/CanvasStore*.swift`, `Canvas/*`, the four legacy Canvas model files, or the Mac workspace coordinator. The Mac stores depend on desktop transactions, recovery and presentation; the dormant phone shell, its APNs delegate and its account-status/bootstrap calls must not be target members. Likewise the old `TaskStoreMobileTests.swift` and `NoteStoreMobileTests.swift` require the retired facade: do not compile them against the new core. Port their create/update, normalization, and changed-fields-only assertions to the new shell before claiming equivalent behavior; the persistence tests do not replace those checks. The phone's `PhoneNoteDocument*` and `PhoneExchangeFixtureTests` files are separate work.

Compile `AtticTests/SharedPersistenceParityTests.swift` in **both** `AtticTests` and `AtticMobileTests`, using the same source reference (module `Attic` via the existing Mac host alias; `AtticMobile` on iOS). Mac still runs `SchemaMigrationTests` and its historical fixture and round-trip suites. The generator owner regenerates and verifies the project, runs the serialized Air builds/tests, compares Mac failures and local entitlements against baseline, and records the stage gate. No platform build or runtime pass is asserted by this manifest.

## What is registered

The Mac registry keeps the same 19 types in the same order. The iPhone registry is exactly `PersistenceController.syncedModelTypes` (12); `deviceLocalModelTypes` contains seven on Mac, none on phone. This is an engineering classification for explicit records later; nothing exports in Stage 2.

| Shared entities | What they represent |
| --- | --- |
| `TaskItem`, `NoteItem`, `NoteAttachment`, `ItemLink`, `TagColour` | User content and relationships. Legacy task file references are not file bytes; a missing payload is not deletion. |
| `DrawCanvasRecord`, `DrawObjectRecord`, `DrawPayloadRecord` | Rebuilt Draw boards, object headers and original payloads. A later exporter must exclude `role == "thumbnail"` payloads and device thumbnail metadata. Inclusion does not freeze or activate the Draw wire schema. |
| `NoteVersion`, `NotePendingEdit` | Historical bytes and pending proposals; inclusion does not grant the phone permission to apply proposals. |
| `TaskNoteAssociation`, `TaskDeletionPreservation` | Logical task/note ownership and recoverability. Define explicit records for portable ownership/tombstone facts before sync; do not transmit serialized workspace guards, physical identifiers, or a device's file-availability evidence wholesale. |

Mac only: the four `Canvas*Item` entities preserve the previous boards without importing them to the phone; `StoreMaintenance` tracks work already performed on this store; `OperationReceipt` is same-store transaction/replay evidence; `TaskAttachmentMigrationRecord` describes the Mac's legacy file migration and reversal. The resulting note placements and attachment data are shared; the local migration receipt is not a transport manifest.

## Note losslessness prerequisites

`NoteItem.content` is authoritative. Existing rows retain the format-zero storage default; *new* notes on both platforms use `NoteContentCodec` and `NoteDocument.currentFormat`. `title`, `body` and `plainText` are projections for display/search, never a reconstruction source. `NoteTextExport`, Markdown, and attributed display text are not persistence formats.

On open, keep the exact input `Data`, stored format and revision alongside any preview. Check both the stored format and the decoded content. Treat `.readOnly(original:reason:preview:)` as immutable; preserve the original bytes even when parsing fails or there is no preview. A shared codec's `.editable` is not permission for a less capable editor to rewrite a note. On a no-op, leave the original bytes, scalar fingerprint (including legacy nil) and revision untouched, even for recognized noncanonical JSON. Until an edit path can preserve the complete structure, show unsupported content read-only; conservatively make the whole note read-only rather than flattening any block. Never rewrite history, proposals or attachment rows merely because their owner was opened or an asset was unavailable.

The editor/exchange gate is separate from storage parity. Use a synthetic Mac-written fixture with stable block/attachment/row/column UUIDs, tables, inline objects and UTF-16 marks, document and nested extras, and a file whose original bytes can be compared. Include malformed or newer content and a missing asset as distinct cases. Assert byte equality after phone open/no-op save and Mac reopen, not just equal decoded objects or display text. A supported edit must retain untouched structure, identities, metadata and attachment bytes; a stale revision or unsafe edit must leave the original intact. The new shared test covers raw persistence through a metadata save, not an editor round trip.

## Cloud boundary

All configuration paths use `cloudKitDatabase: .none`, even with `cloudSyncEnabled: true`, no local-only flag, or the future explicit-engine flag. There is no container identifier, mirroring bootstrap, pre-mirroring backup, cloud-failure retry or launch-time APNs registration in the Mac startup path. Local Mac store URLs, writer leases, and the existing old-note maintenance behavior are retained; the iPhone does not inherit the Mac's maintenance or Canvas UI-test reset path. A future entitled engine must supply its own transport and records, never change this store configuration. The old non-local branch in `AtticTests/TaskStoreTests.swift` (`testCloudConfigurationsUseSeparateEnvironmentStores`) still expects the removed mirror identifier: the test owner should replace that expectation with nil before introducing a non-local **Mac test** configuration. The current local Mac suites compile the nil-expectation branch.

The Mac `TaskStore`, `NoteStore` and legacy Canvas still contain framework-event observation and activity bookkeeping guarded by the local-only configuration. These hooks cannot create a mirrored store, but must be retired or replaced before the Mac ever runs without `ATTIC_LOCAL_ONLY`; they are not an explicit sync engine.
