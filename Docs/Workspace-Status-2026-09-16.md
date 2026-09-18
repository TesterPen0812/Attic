# Attic workspace checkpoint — 16 September 2026

## Current development workspace

The authoritative checkout is `/Users/taha/Developer/attic-task-panels-v2`,
branch `codex/attic-task-panels-v2`. It is a standalone repository with one
registered worktree. The old Documents/Codex path is a retained historical,
partially iCloud-dataless directory; do not use it for current development.
The September 15 archive and retained directories remain intact.

This checkpoint records the accumulated Task Panels V2 implementation,
attachments, panel refinements, reliability/performance fixes, Batch 1/2
remediation, tests, and their existing audit records. It deliberately preserves
the complete candidate rather than inventing separate implementation history
from an interdependent working diff.

## Remote state

Remote branches were freshly fetched on September 16. `origin/main` is
`b8bd3554aa0e1dd95bf71b132940078cf14977a3`, an ancestor of the pre-checkpoint
HEAD `ae6418c1af690e29d15a20344cdb9765a23d3f85` (248 local commits ahead,
zero behind before this checkpoint). No merge/rebase is necessary.
The feature branch has no matching remote branch. Fetch configuration now
tracks all origin branches; origin/HEAD points to origin/main. No push,
remote deletion, or release was performed. A clean local branch does not mean
it has been published or accepted for release.

## Verification and provenance

- All 477 pre-existing tracked/untracked nonignored files are byte-identical
  to the recovery snapshot taken before housekeeping.
- All 166 build/source/project/script/dependency files compared equal to the
  recorded candidate reconstructed from `ae6418c`, the frozen availability-fix
  overlay, and the final D1-fix files. No app behavior changed in this cleanup.
- Fresh project-generation verification passed using
  `PATH=/opt/homebrew/opt/ruby/bin:$PATH bundle exec ruby Scripts/verify_project_generation.rb`.
  System Ruby initially failed because it lacks the lockfile's Bundler version;
  no dependency versions were changed.
- Fresh pre-staging `git diff --check` (previously tracked changes) and
  preview-script `zsh -n` passed. The complete staged checkpoint check also
  examined previously untracked files and reported inherited whitespace in
  historical reports/logs/patches and an extra final blank line in
  `Attic/Window/PanelSurfaceHostingView.swift`. These bytes are preserved for
  provenance; the complete staged whitespace check is not claimed as a pass.
- Existing final build logs contain BUILD SUCCEEDED and TEST BUILD SUCCEEDED.
  The existing full Local XCTest log records 830 executed, 826 passed,
  four skipped, zero failures. These are inspected prior results, not a new run.
  No redundant app build, test run, or desktop session was started.
- Batch 2 closeout is CLOSED as recorded in
  `Batch2-Orchestrator-Acceptance-2026-09-16.md`, section 11. The historical
  earlier open statuses in that record are superseded by section 11.
- Remaining disclosed limitations: plain Edit-menu Undo/Redo was disabled
  during a live draft although keyboard/toolbar routes worked; user-manual
  resize lacks exact-build provenance. Neither is silently upgraded to a pass.

## Durable evidence and recovery

Final evidence formerly only under `/tmp` is copied into
`Batch2-Closeout-Evidence-2026-09-16/`, with a SHA-256 manifest. This includes
the D1 implementation evidence bundle, final R1c/R2c reviews, native segment
1–5 reports, AX evidence, and screenshots. Redundant BMP intermediates were
not copied; PNG evidence and original temporary files remain. Paths inside
copied historical reports retain their original provenance references.

External recovery directory:
`/Users/taha/Developer/Attic-Recovery-Archive-20260916-checkpoint`.
It contains a verified copy of all 477 original files and their SHA-256
manifest, a verified pre-checkpoint all-refs bundle, and a post-checkpoint
all-refs bundle. To recover separately, clone the latter bundle into a new
folder; never restore over a live checkout without checking its state.

The existing September 15 recovery archive, Git checkpoint refs, ignored
build/test products, Attic Daily, and all application stores are preserved.
No disk-wide cleanup or removal of unknown files was necessary.
