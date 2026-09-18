# Attic Daily promotion migration gate — 16 September 2026

## Verdict

**PASS.** A disposable, file-backed SwiftData store reproducing the complete
seven-entity schema installed in Attic Daily at
`8b03586df79c6d667a6aea444b74f7167e552568` opened and migrated under the
candidate schema at `f8a18a09b7d6cc914ab97fdfad252d1f2f8b3d6c`. All legacy
values and external payloads survived. Candidate-only values persisted across a
fresh reopen, and the original seeded store tree remained byte-identical.

The current branch head when this report was written was
`f65d6f2b6e35db66e60d78584049adf328d8c9cc`. Its only changes after `f8a18a0`
are CI workflow/documentation changes; the seven model source files are
byte-identical to `f8a18a0`, as checked by the schema verifier.

No installed app was launched. No real Attic container, preferences, store, or
user data was read or written. All runtime artifacts are under
`/tmp/attic-promotion-migration-20260916`.

## Schema boundary checked

`PersistenceController.swift` is unchanged from installed source to the
candidate. Both use the same Development store selection and the same seven
model entities. The persisted change is additive:

- `TaskItem`: optional `parentID` and optional `imageReferencesData`.
- `NoteAttachment`: optional `inlineOffset`, `displayWidth`, and
  `displayHeight`.
- `CanvasImageItem`: defaulted `encodedByteCount` and `contentDigest` scalars.

The harness declarations are reproductions, not the app's compiled model
types. To control transcription risk,
`/tmp/attic-promotion-migration-20260916/verify-schema-fields.rb` extracts every
persisted property, type, and `@Attribute` from all seven model files using
`git show` at both exact commits and compares them to the reproduced schemas.
It reported:

```text
installed_persisted_fields_and_attributes=MATCH
candidate_persisted_fields_and_attributes=MATCH
current_head_model_sources_match_candidate=true
```

Computed and `@Transient` properties are deliberately excluded because they do
not participate in the SwiftData schema.

## Migration exercised

The installed-schema seed contains representative rows for `TaskItem`,
`NoteItem`, `NoteAttachment`, `CanvasBoardItem`, `CanvasStrokeItem`,
`CanvasImageItem`, and `CanvasSemanticObjectItem`, including timestamps,
ordering, status, replica versions, board generation, tombstone fields, and
binary payloads.

The note attachment uses a 2 MiB payload and the canvas image uses a 3 MiB
payload. Core Data placed both in real
`.development_SUPPORT/_EXTERNAL_DATA/` files. The seed container was closed and
its WAL explicitly checkpointed (`0|0|0`) before the complete store directory
was copied. Only the copy was opened with the candidate schema.

The candidate open verified:

- all seven entity counts, IDs, legacy scalars, timestamps, and payloads;
- nil defaults for both new task columns and all three note-attachment columns;
- zero/empty defaults for legacy canvas-image metadata;
- exact preservation of the 2 MiB and 3 MiB external payload bytes.

The harness then exercised the exact image backfill algorithm used by
`CanvasImageItem.backfillPayloadMetadataIfNeeded()`: byte count plus the first
16 bytes of SHA-256 represented as lowercase hex. It verified that the write
did not change image bytes, mutation version, update timestamp, board
generation, or tombstone state. It wrote candidate-only task and attachment
values, inserted a child task, closed the container, reopened it, and verified
all legacy and candidate values again.

The backfill method was reproduced directly in the harness; this run did not
compile or invoke `CanvasStore` itself. Fresh repository persistence tests cover
the production store path separately. This gate establishes the SwiftData
schema migration and the backfill's data transformation, not installed-app UI
or CloudKit behavior.

## Original-store immutability

The closed, checkpointed seed consisted of the SQLite store and two external
payload files. SHA-256 hashes were captured before the copied store was opened
and recomputed after migration, backfill, candidate writes, close, and reopen.
The mappings were identical and the harness reported
`original_seed_unchanged=true`.

The specific external-data filenames are generated afresh on each reproduction;
their content hashes are stable. The final run's tree hash list is retained at
`/tmp/attic-promotion-migration-20260916/seed-tree-sha256.txt`.

## Reproduction

```sh
/tmp/attic-promotion-migration-20260916/run-migration-gate.zsh
```

Final output:

```text
MIGRATION_GATE=PASS
installed_sha=8b03586df79c6d667a6aea444b74f7167e552568
candidate_sha=f8a18a09b7d6cc914ab97fdfad252d1f2f8b3d6c
entities=7
seed_files=3
original_seed_unchanged=true
candidate_round_trip=true
external_payloads_preserved=true
image_backfill_preserved_replica_fields=true
REPRODUCTION=PASS
```

Key artifact hashes after the final run:

```text
691c6e71093269cc5d8483e87b099d3f85c642ddc3315d9ae72e48b508ff0428  MigrationGate.swift
7505312c4dde2be4bdc7fd7033bc33d5d2bf491ba714285f33c0b02b78410a17  run-migration-gate.zsh
0cc5245fe7446dbcf6d5223b8e7363ba030028c69b78f30303bd9c652377cbf3  verify-schema-fields.rb
8a65ca1af5bec2b6ae488fdacb1c98d958002a959adb74d20c8fe6a5f9f34c5c  run.log
616b4693bfa3ab45bd581cc4b87482d670d14bdad16b274cdb4ced0dd6f7b90c  schema-property-comparison.txt
23ff39bff80336e132d9223f8aeb0272ad5fa6ab90e0417c18aca921ccb223e8  seed-tree-sha256.txt
28b7b15a5cf881bc8e8664347bf1f716a7e01399107db1cebb264240ea56642e  seed-checkpoint.log
```

This removes the schema-migration blocker identified during promotion review.
The documented installer backup and focused first-launch persistence smoke are
still required because a synthetic migration cannot prove the contents of an
unknown real store or installed-app behavior.
