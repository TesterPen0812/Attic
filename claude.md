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



## Model Selection

Rankings, higher = better. Cost reflects what I actually pay (OpenAI is near-free for me due to a deal), not list price. Intelligence is how hard a problem you can hand the model unsupervised. Taste covers UI/UX, code quality, API design, and copy.

| model | cost | intelligence | taste |
| --- | --- | --- | --- |
| gpt-5.6-sol | 9 | 8 | 5 |
| sonnet-5 | 5 | 5 | 7 |
| opus-4.8 | 4 | 7 | 8 |
| fable-5 | 2 | 9 | 9 |

How to apply:

- These are defaults, not limits. You have standing permission to override them: if a cheaper model's output doesn't meet the bar, rerun or redo the work with a smarter model without asking. Judge the output, not the price tag. Escalating costs less than shipping mediocre work.
- Cost is a tie-breaker only; when axes conflict for anything that ships, intelligence > taste > cost.
- Don't let cost prevent you from using the right model for the job. Instead, take advantage of cheaper options to get more information and try things before moving the work to a more expensive option.
- Bulk/mechanical work (clear-spec implementation, data analysis, migrations): gpt-5.6-sol — it's effectively free.
- Anything user-facing (UI, copy, API design) needs taste ≥ 7.
- Reviews of plans/implementations: fable-5 or opus-4.8, optionally gpt-5.6-sol as an extra independent perspective.
- Never use Haiku.
- Mechanics: gpt-5.6-sol is only reachable through the Codex CLI — `codex exec` / `codex review` (my `~/.codex/config.toml` defaults to gpt-5.6-sol). Use the codex-implementation, codex-review, and codex-computer-use skills; for work they don't cover (investigation, data analysis), run `codex exec -s read-only` directly with a self-contained prompt.
- Claude models (sonnet-5, opus-4.8, fable-5) run via the Agent/Workflow model parameter.

Using gpt-5.5 inside workflows and subagents (the model parameter only takes Claude models, so use a wrapper):

- Spawn a thin Claude wrapper agent with `model: 'sonnet', effort: 'low'` whose prompt instructs it to write a self-contained codex prompt, run `codex exec` via Bash, and return the report (use `schema` on the wrapper to get structured output back).
- Always label these agents with a `gpt-5.6-sol:` prefix, e.g. `{label: 'gpt-5.6-sol:review-auth'}` — the workflow UI shows the wrapper's Claude model, so the label is the only indication the real worker is gpt-5.6-sol.
- Codex runs can exceed Bash's 10-minute timeout: pass an explicit timeout, or run in the background and poll for the report file.
- Parallel gpt-5.6-sol implementation agents must use `isolation: 'worktree'` so codex edits don't collide in the shared checkout.
- Workflow token budgets only count Claude tokens; codex work is free and invisible to `budget.spent()`.

## Long-running Codex Work

gpt-5.6-sol is exceptionally capable on long-running tasks. Give it substantial, multi-step work when it is the right model for the job; do not split work up merely because it is large.

- The quality of the result depends on the prompt. Provide a detailed, self-contained brief: goal, relevant context, constraints, files or systems in scope, expected deliverables, and how to verify completion.
- State important decisions and non-negotiable requirements explicitly. Do not assume the model will infer project-specific conventions or the desired tradeoffs from a short prompt.
- For long tasks, ask it to inspect the current state first, execute the work end to end, and report the changes, verification, and any remaining risks.
- If the work can safely run in parallel, keep each task's ownership and worktree boundaries explicit so agents do not overlap.
