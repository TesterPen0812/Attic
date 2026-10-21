# Historical build compatibility fixtures

These are synthetic, on-disk SwiftData stores written by temporary XCTest tools compiled with each named commit’s unchanged application sources. No owner store or container was used. The fixture writer uses the build’s models, codec, editor-compatible documents, NoteStore, TaskStore, attachment importer, proposal/history writers, LinkStore, OldNotesPurge, and NoteDraftJournal.

Generated on 2026-10-16 with macOS 27.0 / SDK 27.0. `BuildCompatibilityTests` copies each directory to a unique temporary path before opening or modifying it. `snapshot.json` records every physical row and persisted field in the tested data kinds; `note-*.json` contains the original document bytes. The store’s `NoteFiles`, `TaskFiles`, and `NoteDrafts/staged` directories hold real attachment bytes. `development.store` is local-only (`cloudKitDatabase: .none`); the filename comes from the test host’s configuration.

| Writer commit | Fixture directory | Files | Bytes |
|---|---|---:|---:|
| `4b25a1fab3217e177dcd0f70d7f0628d496493d3` | `4b25a1fa/` | 17 | 270,856 |
| `81c124d604f03554e998782c94544410717a9d92` | `81c124d6/` | 18 | 273,324 |

Coverage includes title/body, headings 1–3, all three nesting levels of bullets/numbers/quotes, mono, both checklist states, every inline mark kind, inline date, divider, table cells/marks/column width/alignment, image dimensions and sizing hints, file cards, unknown document/block metadata, note metadata, tags/colours, task page ownership, four history rows, two pending proposals (including deletion), three link kinds, a soft-deleted note, and duplicate note UUIDs. Int12 additionally writes explicit highlight colours.

Tasks cover title, all persisted metadata fields, active/subtask/done/deleted rows, due days, tags, priority, ordering, image reference bytes, removed attachment bytes, completion origin, existing Done history, the local-midnight boundary, a missing completion time, a completed parent/child family, and divergent duplicate UUIDs.

The nonempty purge marker records an intentionally removed format-0 fixture note. That removal is the owner-approved 2026-10-09 policy. Tests require the marker to survive and prevent a second purge, and require current recovery files and staged bytes to survive cleanup.

The detailed generation report (source, commands, measurements in both directions, file hashes, and CI evidence) is retained privately and is unavailable in this repository. The historical worktrees and their temporary tools were removed after measurement. Do not regenerate these golden stores with the current build.
