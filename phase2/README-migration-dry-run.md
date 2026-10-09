# S6 migration dry run

**No owner store has been located, read or copied during S6.** Run only after explicitly approving the dry run and quitting the app that writes the supplied store. There is no default directory and no discovery of store locations.

```zsh
phase2/migration-dry-run.zsh --approve-owner-store --source-quiescent \
  --store-directory '/owner-supplied/directory-containing-the-store' \
  --store-name 'owner-supplied.store'
```

The directory must contain the SQLite file, its WAL/SHM sidecars when present, and its external binary-storage support directories. Copy the whole store directory, not SQLite alone. Never use this task to reset or migrate the original. `--approve-owner-store` records the owner's opt-in; the agent must still obtain explicit approval before invoking it on owner data. `--fixture` is restricted to this worktree's `.build` or OS temporary directories.

The script keeps a temporary copy and reports its location. Files/directories in the copy are made read-only. An isolated unit-test host opens Core Data with `NSReadOnlyPersistentStoreOption`, automatic and inferred schema migration both disabled, and never constructs `NoteStore` or commits a migration. Each legacy family passes through the production plan, inverse, and real TextKit 2 round trip. Reports contain IDs, state, refusals, attachment/missing-byte counts, normalized line breaks and snapped anchors, without note text or attachment bytes. Supported and unsupported existing documents are classified; unsupported bytes are never rewritten. Deleted families are skipped. Incompatible store schemas are refused rather than upgraded.

`migration-report.json` describes candidates/refusals; `integrity-report.json` checks SHA-256 inventories of the source and every copied file before/after; `test.log` keeps runner/build diagnostics. The script fails on a runner error or changed source/copy. A compatibility refusal is not a migration pass. Close the source writer first: a live WAL copied across files is not a consistent snapshot. No report commits or repairs anything. The temporary folder is retained for review; its copy has read-only permissions.

Verification: `python3 phase2/test_migration_dry_run.py` checks syntax/authorization gates. `NotesMigrationAcceptanceTests` builds durable fixtures and exercises rollback, fresh-context reopen, recovery, editable refused legacy and byte-preserved future documents. The compatible script end-to-end check uses an explicitly exported constructed fixture only.
