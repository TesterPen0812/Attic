# Attic Project Instructions

<!-- BEGIN ATTIC DEVELOPMENT CONTRACT -->
## Development Contract — macOS-first and local-first

Attic is developed as a macOS-first, local-first app. The iPhone app and
CloudKit synchronization are current scope under the written activation and
validation plan (`Docs/iPhone/activation-plan.md`). They are
built in that plan's stages and gates, and are not gates for ordinary Mac
feature development, local previews, branch integration, or a macOS-only
release. Do not claim that iPhone or sync functionality works beyond the last
stage whose gate has passed and been recorded.

### Current product identity

- The official macOS bundle identifier is `com.taha.Attic`.
- The official Apple development team is `ZGZWS73268` unless a developer
  supplies a local signing override.
- This identity starts with a fresh sandbox and local SwiftData store. Do not
  copy, delete, or mutate data from the former `com.emanueledipietro.Attic`
  container without explicit user approval.
- Isolated previews may use a unique `com.taha.Attic.<preview>` identifier,
  display name, process name, build directory, and local store so multiple
  branches can coexist.

### Current persistence and signing rules

- Normal macOS development is local-only. It must not require CloudKit, APNs,
  an iPhone target, a Production schema, TestFlight, or production signing.
- Local-only builds must compile with `ATTIC_LOCAL_ONLY`, use sandbox/network
  entitlements without CloudKit or APNs, and never open a production store.
- Keep the app local-first: saves must remain durable, failed saves must roll
  back cleanly, and imported model changes must replace stale `ModelContext`
  instances before presentation.
- App-level UUIDs must remain duplicate-safe. Deduplicate only for presentation;
  mutations and deletion apply to every physical replica with the same UUID.
- Done-task cleanup uses `completedAt` relative to the start of the current local
  day. A divergent duplicate prevents destructive cleanup until replicas agree.
- Never delete, reset, migrate, or replace user data as a debugging shortcut
  without explicit approval.

### Development and preview verification

1. Preserve unrelated user changes and worktree boundaries.
2. Regenerate `Attic.xcodeproj` from `Scripts/generate_project.rb` and run
   `Scripts/verify_project_generation.rb` after project-input changes.
3. Build the affected macOS target and run relevant unit tests.
4. For UI work, install or launch a uniquely named local-only preview and report
   the exact branch, commit, executable, bundle identifier, and manual UAT that
   remains.
5. Do not present source review, compilation, unit tests, or a local-only preview
   as proof of CloudKit, APNs, iPhone, TestFlight, or Production behavior.

### iPhone and CloudKit work

The iPhone app and CloudKit synchronization are current scope, activated under
the written plan `Docs/iPhone/activation-plan.md`. Work follows
its stages in order; a stage starts only when the previous stage's "done when"
check has passed and been recorded with branch, commit, identities and devices.

Identities:

- The iOS app is `com.taha.AtticMobile` (previews `com.taha.AtticMobile.<preview>`)
  on team `ZGZWS73268`.
- The only CloudKit container is `iCloud.com.taha.Attic`, created in Taha's own
  Apple developer account. Development sync testing on the Mac uses the isolated
  identity `com.taha.Attic.syncdev`, never the official app or an owner-data
  preview.
- Never restore or reference the former owner's bundle identifiers, team, or
  CloudKit container, in build settings, entitlements, or source.

Builds:

- Local-only Mac builds keep `ATTIC_LOCAL_ONLY`, `cloudKitDatabase: .none`, and
  sandbox/network entitlements without CloudKit or APNs, exactly as described
  above. Ordinary Mac work never requires sync, an iPhone build, or signing
  with Taha's account.
- Sync code compiles only under `ATTIC_CLOUD_SYNC`, in separate build
  configurations; a configuration never sets both flags. Removing
  `ATTIC_LOCAL_ONLY` is not a way to enable sync.
- The iPhone app builds local-only, without CloudKit or APNs entitlements,
  until the plan's Development sync stage.
- Add CloudKit or APNs entitlements only for the Taha-owned container, after it
  exists, and only to the configurations the plan names. Never add speculative
  entitlements to make signing errors disappear.

Sync rules:

- Synchronization uses `CKSyncEngine` with explicit private-database records
  over local SwiftData. SwiftData's built-in CloudKit mirroring stays off, and
  the two never run over the same data.
- Local saves stay durable and roll back cleanly whether or not the network is
  available; outgoing sync work is recorded in the same transaction as the save.
- Imports are transactional and idempotent, never echo back as local edits,
  and replace stale `ModelContext` instances before presentation.
- Note conflicts preserve every competing revision for review; no silent
  last-writer-wins on note content. Absence of a record or asset is never
  treated as deletion; deletions are explicit tombstones.
- The UUID duplicate-safety and Done-cleanup rules above apply across devices:
  record names derive from type and UUID, imports apply to every physical
  replica, divergent replicas block destructive cleanup, and a device runs
  destructive cleanup only after a completed fetch.
- Development and Production each have separate stores, engine state, queues
  and change tokens. Development CloudKit pairs only with development APNs,
  and Production CloudKit only with production APNs.
- Models stay CloudKit-compatible: optional or defaulted attributes, no
  uniqueness constraints, and an explicit list of synced and device-local
  model types shared by the Mac and iPhone.

Validation before release (each item mapped to a check in the plan):

- the Taha-owned container, verified in CloudKit Console and in installed-app
  entitlements;
- deliberate Mac/iPhone scope and model parity;
- matching Development/development APNs and Production/production APNs;
- separate Development and Production stores;
- CloudKit-compatible models;
- remote-notification registration, sync-engine event observation, fresh-context
  import refresh, and bounded event-driven activity assertions;
- Development schema inspection, Production schema deployment, installed-app
  entitlement inspection, and real-device two-way synchronization validation.

Simulator runs, unit tests, fake-transport tests, and local-only previews are
not proof of CloudKit, APNs, real-device, TestFlight, or Production behavior.
Creating the container, signing with Taha's account, registering devices,
deploying the Production schema, TestFlight, and turning on sync for the
official app's existing library are Taha's actions or need Taha's explicit go.
Never delete, reset, or replace user data, or sync a real library for the
first time, without explicit approval and a backup.

Keep this Development Contract synchronized verbatim between root `AGENTS.md`
and `claude.md`. Changing the iPhone or CloudKit scope, identities, or sync
approach requires updating both files and the activation plan together.
<!-- END ATTIC DEVELOPMENT CONTRACT -->

## Working in this repository

- Start with `README.md`: what ships, how to build a preview, and how the
  tests and CI lanes are organised. `Docs/README.md` lists the few documents
  that still govern current work. Older ledgers and handoffs were removed from
  the working tree on 2026-10-20 and live only in Git history; do not treat
  them as current.
- Run `xcodebuild` through `Scripts/xcodebuild_locked.sh`, which serialises
  builds and tests on one machine. Local unit tests run in the invisible
  `AtticUnitTestHost` and must not show windows or take the keyboard; tests
  that need a key window opt in with `TEST_RUNNER_ATTIC_KEY_WINDOW_TESTS=1`.
- Launch previews with `./script/build_and_run.sh` or
  `Scripts/launch_local_preview.zsh` and a unique `com.taha.Attic.<preview>`
  identity. Add `--optimized` when judging feel or speed.
- Record design-system changes in `Attic/DesignSystem/CHANGELOG.md`.
- The Canvas page is the pre-redesign implementation, kept as it is until its
  rebuild. Do not extend it as part of other work.
