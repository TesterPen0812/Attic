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



## Model Selection

Which model does what. These are defaults, not limits: if a model's output doesn't meet the bar, redo the work with a stronger one without asking. Judge the output, not the price; escalating costs less than shipping mediocre work. When axes conflict for anything that ships: intelligence > taste > cost.

| Model | Use it for | Not for |
| --- | --- | --- |
| **Opus 5.5** (high; xhigh for the hardest problems) | Anything a person sees: UI, interaction, motion, copy and API design. Designing new screens and components, hard or unclear bugs, judgement calls about the owner's decisions, and reviewing Sol's work. | Routine fix lists. |
| **GPT-6.1 Sol** (`gpt-6.1-sol`, through the Codex CLI; high to build, xhigh to review) | The engine and data safety, merges, CI and performance investigations, all computer use and on-screen checks, long multi-step jobs, and reviewing Opus's work. | Designing UI (its taste is weaker). |
| **Sonnet 5.5** | Mechanical work only: a written fix list where each fix is already decided, or known CI failures back to green. | Root causes, design, reviews, anything visible. |
| **Haiku 5.5** | Cheap, bounded lookups and searches where it saves cost. | Placeholder or no-op calls; anything that ships. |
| **GPT-6 Pro** (ChatGPT, run by the owner) | Deep external reviews of a whole pull request or design. | Anything that needs the repo's tools. |
| **Fable** | Never. | Everything. |

Rules:

- **Never let a model review its own work.** Opus reviews Sol's work and Sol reviews Opus's.
- Cost is a tie-breaker only. Use cheaper options to gather information and try things before moving the work to a stronger model; don't let cost keep the right model off the job.
- Claude models run through the Agent/Workflow `model` parameter.
- GPT-6.1 Sol is reachable only through the Codex CLI. Always pass the model and effort explicitly, and check the `model:` line at the top of the run log: `codex exec -m gpt-6.1-sol -c model_reasoning_effort=high` (or `xhigh` to review). Codex runs use the ChatGPT Codex usage limit, so they are not free.
- Stagger parallel Codex starts; concurrent runs share one login.
- Write Codex briefs in plain quality-work wording. Words like "adversarial" or "attack" can trip the content filter and stop a run midway.

Using GPT-6.1 Sol inside workflows and subagents (the `model` parameter only takes Claude models, so use a wrapper):

- Spawn a thin Claude wrapper agent with `model: 'sonnet', effort: 'low'` whose prompt has it write a self-contained Codex prompt, run `codex exec` through Bash, and return the report (use `schema` on the wrapper to get structured output back).
- Label these agents with a `gpt-6.1-sol:` prefix, for example `{label: 'gpt-6.1-sol:review-auth'}`. The workflow UI shows the wrapper's Claude model, so the label is the only sign that the real worker is Sol.
- Codex runs can exceed Bash's 10-minute timeout: pass an explicit timeout, or run in the background and wait for the report file.
- Parallel Sol implementation agents must use `isolation: 'worktree'` so their edits don't collide.
- Workflow token budgets only count Claude tokens; Codex work is invisible to `budget.spent()`, but it still uses the Codex usage limit.

## Long-running Codex Work

GPT-6.1 Sol is very capable on long-running tasks. Give it substantial, multi-step work when it is the right model for the job; don't split work up merely because it is large.

- The quality of the result depends on the prompt. Provide a detailed, self-contained brief: goal, relevant context, constraints, files or systems in scope, expected deliverables, and how to verify completion.
- State important decisions and non-negotiable requirements explicitly. Don't assume the model will infer project-specific conventions or the desired tradeoffs from a short prompt.
- For long tasks, ask it to inspect the current state first, execute the work end to end, and report the changes, verification and any remaining risks.
- If the work can safely run in parallel, keep each task's ownership and worktree boundaries explicit so agents don't overlap.
