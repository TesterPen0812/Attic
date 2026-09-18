# Attic Project Instructions

<!-- BEGIN ATTIC DEVELOPMENT CONTRACT -->
## Development Contract — macOS-first and local-first

Attic is currently developed and evaluated as a macOS-first, local-first app.
The iPhone companion and CloudKit synchronization are deferred work, not gates
for ordinary feature development, local previews, branch integration, or a
macOS-only release. Do not claim that deferred functionality works until it is
explicitly re-enabled and validated.

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

### Deferred iPhone and CloudKit work

The existing sync implementation may remain in source for future work, but it
must stay dormant in current local-only builds. Re-enabling it is a separate,
explicit project requiring all of the following before release:

- a CloudKit container owned by Taha's Apple developer account;
- deliberate Mac/iPhone scope and model parity;
- matching Development CloudKit/development APNs and Production
  CloudKit/production APNs;
- separate Development and Production stores;
- CloudKit-compatible models with defaults or optionality and no unsupported
  uniqueness constraints;
- remote-notification registration, remote-change and CloudKit-event
  observation, fresh-context import refresh, and bounded event-driven activity
  assertions;
- Development schema inspection, Production schema deployment, installed-app
  entitlement inspection, and real-device two-way synchronization validation.

Never restore the former owner's bundle identifier, team, or CloudKit container
as a shortcut. Never add speculative CloudKit/APNs entitlements to make signing
errors disappear.

Keep this Development Contract synchronized verbatim between root `AGENTS.md`
and `claude.md`. A future decision to make iPhone or CloudKit current product
scope must update both files and include a written activation and validation
plan.
<!-- END ATTIC DEVELOPMENT CONTRACT -->
