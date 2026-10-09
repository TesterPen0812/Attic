# S6 migration dry run

Run only on an explicitly approved, quiescent **staged copy**. The script refuses protected owner containers and symlinks. It never discovers stores or opens the staged source with SQLite. Copy the complete Application Support store family, including WAL/SHM, `.development_SUPPORT/`, and `Attic/` file storage.

```zsh
phase2/migration-dry-run.zsh --approve-owner-store --source-quiescent \
  --store-directory '/owner-supplied/staged-copy' \
  --store-name development.store
```

The script hashes the source and copies the entire supplied directory to a disposable writable temporary directory. The isolated Local unit-test host opens that copy with **`PersistenceController.makeContainer(cloudSyncEnabled: false, storeDirectory:)`**, the local app's real persistence constructor and its inferred lightweight schema migration. The supplied store name must match that configuration (`development.store` in Local builds); a mismatch is refused rather than opening an empty store. CloudKit stays disabled. No NoteStore startup reconciliation, daily cleanup, attachment repair, or note-format commit runs.

After the schema opens, a read-only audit groups physical note replicas by UUID and refuses divergent or partly deleted families. Live legacy families pass through production plan, inverse verification, and a real TextKit 2 round trip. Existing documents are classified as supported or unsupported; note bytes are never rewritten. Attachment bytes are checked in SwiftData external storage or the copied `Attic/Attachments/v1` directory. Counts distinguish physical rows and logical note families, clean migration candidates, refusal reason classes, legacy/already-new notes, deleted families, attachments found/missing, tasks, and canvas boards/content. “Migrated cleanly” means the format dry run verified; it does not mean note-format changes were committed.

`migration-report.json` contains IDs, counts, and states only; errors contain domain/code only. `integrity-report.json` proves the staged source's full SHA-256 file inventory is unchanged, and fingerprints of every old persisted user field (as a multiset preserving duplicate physical rows) match before/after schema migration. SQLite bookkeeping columns are excluded. Private inventories/fingerprints and **all working copies are deleted**, including runner-failure paths; only reports and filtered runner status/count diagnostics remain. Native runtime diagnostics are discarded before being written to the retained log. A runner failure, incompatible schema, changed source, or altered old rows is a failure, never a pass.

## Daily 1.0.0 schema compatibility

The approved staged Daily store's seven entity hashes exactly match `SchemaMigrationTests.baseRevisionEntityHashes` (the `PrePhase0` models from `f2c737a`). No VersionedSchema or custom MigrationPlan is needed: all seven entities and their attributes retain names, types, and optionality. There are no removed or renamed fields. Additions:

- `TaskItem`: optional deletion/link/attachment/Done/due/completion-origin fields, empty `deletionMembersRaw` and `tagsRaw`, and default-zero `listOrderVersion`.
- `NoteItem`: optional deletion, pin, document content, task/revision/file metadata fields; empty tags/plain text; default-zero format/revision/image/file counts. Existing title/body remain.
- `NoteAttachment`: optional `deletedAt`.
- `CanvasBoardItem`: empty tags and optional purge/recent-deletion/content-count fields.
- Stroke, image, and semantic-object schemas are unchanged.
- New entities: `ItemLink`, `NoteVersion`, `NotePendingEdit`, without required links to old rows or uniqueness constraints.

`testDailyToRedesignDiffIsEntirelyAdditiveAndInfersAMapping` checks the attribute diff and inferred mapping. The exact 1.0.0 durable fixture exercises migration through the application, duplicate preservation, externally stored attachment bytes, missing payloads, and reopen. Existing schema tests additionally cover all seven models, file references, defaults, and cleanup/restore safety. `python3 phase2/test_migration_dry_run.py` checks authorization, protection, copying, duplicate-row fingerprints, and cleanup. The original refusal was specific to the previous read-only harness, which explicitly disabled schema migration.
