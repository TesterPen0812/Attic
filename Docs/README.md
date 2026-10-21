# Docs

These documents still describe current behaviour or tooling.

| File | What it covers |
|---|---|
| [DailyApp.md](DailyApp.md) | How the everyday app is installed from a reviewed commit, and how it differs from development previews. |
| [Native-Verification-Playbook.md](Native-Verification-Playbook.md) | How an on-screen verification pass launches a preview, proves which build is running, and reports results. |
| [Appearance-Model-2026-09.md](Appearance-Model-2026-09.md) | The appearance settings model and Tint calibration. Source comments point here. |
| [performance-baseline.md](performance-baseline.md) | The Phase 0 performance harness and its recorded baselines (the `performance-baseline-*` files). |

## Removed history

On 2026-10-20 the August and September review ledgers, audit reports, agent
handoffs and evidence folders were removed from the working tree, together
with the root files `CANVAS-DESIGN.md`, `HANDOFF-scroll-under-controls.md` and
`design-qa.md`. They described earlier builds and no longer govern any work.
They remain in Git history, for example `git show 55d02660:CANVAS-DESIGN.md`
or `git ls-tree -r --name-only 55d02660 Docs`.
