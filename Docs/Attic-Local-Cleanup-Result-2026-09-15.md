# Attic Local Cleanup — Result Report — 2026-09-15

Executed (not proposed). Scope: local Attic worktrees, branches, and Git layout under
`/Users/taha/Developer`, plus archival of retired old-cluster content. Remote
branches, tags, and remote config were not changed; no commits were made to the
current working branch; no app implementation or UI was touched; no agents or
processes were stopped.

- **Recovery archive:** `/Users/taha/Developer/Attic-Recovery-Archive-20260915` (1.2 GB)
- **Archive restore guide:** [README-RESTORE.md](file:///Users/taha/Developer/Attic-Recovery-Archive-20260915/README-RESTORE.md)
- **Disk reclaimed:** ~15.5 GB (free 6.5 GB → 22 GB on `/System/Volumes/Data`)
- **Status:** complete for every authorized local Attic target. Two old-cluster
  paths and one host path are deliberately **retained** with exact reasons below
  (iCloud-dataless content and out-of-scope user data).

## 1. What the workspace looks like now

| Item | State |
|---|---|
| `/Users/taha/Developer/attic-task-panels-v2` | Sole remaining Attic workspace; **standalone** `.git` (`git-dir=.git`, `common-dir=.git`, no `commondir`) |
| Branch | `codex/attic-task-panels-v2` @ `ae6418c` — unchanged |
| Local branches | 1 (current) |
| Remote-tracking refs | 1 (`origin/codex/attic-local-baseline`) — unchanged, stale, untouched |
| Tags | `attic-daily-1-8b03586df79c` — kept |
| Synara checkpoint refs | 95 — kept, none pruned |
| Worktrees | 1 (the current checkout) |
| Unreachable real commits | Still present (no gc/prune run): `3915af7`, `950d6a1`, `1ca2fe2`, `6789d34`, `fb00756`, `7ad978d`, `f3ec4a3` |
| Current source bytes | Byte-identical before/after (452-file baseline; final diff only the `.git` pointer file that was intentionally replaced by a real `.git` directory) |
| Git functionality | `status`, `log`, `diff`, `show`, `worktree add/remove` all verified working after promotion |

## 2. Recovery archive contents (all verified before any removal)

| Archive item | Preserves | Verification |
|---|---|---|
| `bundles/attic-shared-repo-ALLREFS-incl-synara-checkpoints-20260915.bundle` (64 MB) | All **116** final refs: 19 local branches, remote-tracking ref, tag, worktree HEADs, 95 Synara checkpoints | Every live `show-ref` entry present at identical commit; bundle reports complete history |
| `bundles/attic-unreachable-45-commits-and-trees-20260915.bundle` (66 MB) | 45 unreachable commits under restorable `refs/archive/unreachable/N-<oid>` refs | 45/45 resolve after `fetch`; genie geometry (380 lines each), handoff doc, corner-pull sketch (399,322 B), settings PNG (1,003,597 B) all materialize |
| `bundles/unreachable-objects-pack/` | Raw pack of the unreachable object closure — 3,937 objects (344 commits, 1,725 trees, 1,868 blobs) | `verify-pack` OK; bare-repo `fsck` clean |
| `old-cluster/shared-git-metadata/` (71 MB) | Full copy of the former common `.git` (objects, refs, reflogs, worktree registrations, hooks, config) | Restores to **116** refs / fsck clean |
| `worktree-snapshots/attic-{animation-devin-local, animation-fable-51, clear-reading-experiment, funnel-redo, hover-pinned-subtasks, scroll-under-controls, ux-refinement}/` | Every retired worktree's tracked+untracked source bytes | Hash-identical to live directories immediately before removal (194–210 files each) |
| `worktree-snapshots/attic-task-panels-v2-CURRENT/` | Current checkout full source incl. all reviewer reports | Hash-identical to live (only `.git` pointer excluded) |
| `worktree-snapshots/attic-recovery-20260907-HOST/` | Former main checkout source | Hash-identical; committed content identical to `bd5e246` (173 files incl. 1 untracked) |
| `old-cluster/old-repo-Attic/` (328 MB) | Old repository's readable Git metadata: 3 verified packs, `packed-refs`, 273 refs, 25 worktree registrations, reflogs | `verify-pack` OK on all packs |
| `old-cluster/old-repo-lineage-allrefs-20260915.bundle` (11 MB) | 480-commit old lineage, 463/463 refs including the 8 OIDs the earlier inventory believed absent (`f16cf351`, `b63dfac4`, `dc2415de`, `5149a691`, `9db180d9`, `31769942`, `455353846`, `abb7e550`) | Bundle verify: complete history |
| `old-cluster/Attic-canvas-ink-8063d92-20260827.bundle` | Old canvas-ink bundle @ `8063d92c` | Verified |
| `old-cluster/attic-comprehensive-themes-integration/` | Nested standalone repo all-refs bundle (37 refs incl. unique `994b447`, `8b8388c`, `71c24a3`) + source snapshot | Verified |
| `old-cluster/codex-worktrees-snapshots/` | All 21 readable `/Users/taha/.codex/worktrees/*` source trees (0 dataless) | Snapshot manifests present |
| `old-cluster/test-evidence/` | Funnel-redo cited xcresults (incl. `OriginalMotionFinal` = 155 passed/0 failed) + 41 `xcresulttool` summaries + recovery-host small xcresults | `OriginalMotionFinal` re-read successfully |
| `manifests/` | SHA-256 manifests (current before/after, every snapshot, bundles, old cluster), refs/worktree/reflog snapshots, unreachable-object lists, branch-deletion map, iCloud blocker lists | `ARCHIVE-bundles.sha256` verifies OK |

## 3. Removed items and reason

| Removed | Reason |
|---|---|
| Worktrees `attic-animation-fable-51`, `attic-animation-devin-local`, `attic-clear-reading-experiment`, `attic-funnel-redo`, `attic-hover-pinned-subtasks`, `attic-scroll-under-controls`, `attic-ux-refinement` | Retired by user decision; branches contained or unique work snapshotted; each `git worktree remove` verified individually |
| 18 old local branches (`animation-devin-local`, `animation-fable-51`, `canvas-input-20260908`, `clear-reading-experiment`, `funnel-redo`, `gradient-settings-20260908`, `hover-pinned-subtasks`, `local-baseline`, `mcp-subtasks-composer`, `motion-20260908`, `notes-layout-20260908`, `readable-surfaces-20260908`, `readable-themes-20260908`, `recovery-20260907`, `refinement-20260908`, `scroll-under-controls`, `theme-review-20260908`, `ux-refinement`) | Re-verified live at deletion time: 0 patch-unique commits (`git cherry`) for all; all tips archived at identical commits; exact map in `manifests/branches-removed-map.txt` |
| `/Users/taha/Developer/attic-recovery-20260907` (3.2 GB) | Retired host checkout; its `.git` was **moved** (not deleted) into the current checkout by the promotion step; source archived and verified identical; no process held it |
| Retired worktrees' `.build` caches (≈13.5 GB total, incl. 5.7 GB hover-pinned, 3.9 GB scroll-under-controls, 3.2 GB host, 1.8 GB ux-refinement, 1.0 GB funnel-redo) | Reproducible build output inside the retired worktrees only; cited xcresult evidence archived first |

## 4. Retained items and reason

| Retained | Reason |
|---|---|
| Current checkout `.build` (3.8 GB) | Test evidence (Batch 1 xcresults); inventory said keep longest |
| `refs/synara/checkpoints/*` (95) | Only safety net for the uncommitted current tree; never pruned |
| Remote-tracking ref, tag, `origin` config | Remote scope explicitly unchanged; no fetch/push/prune performed |
| `/Users/taha/Documents/Codex/2026-07-19/d/work/Attic` (440 MB) | **iCloud-dataless**: 222 unreadable files (including `.git/HEAD`, `ORIG_HEAD`, `COMMIT_EDITMSG`, `FETCH_HEAD`, 3 loose objects). `brctl download` did not materialize them. Positively archived: all 3 packs (verified), readable refs, source. Not treated as empty. |
| `/Users/taha/Documents/Codex/2026-07-19/d/work/Attic-native-liquid-glass-preview` (347 MB) | **iCloud-dataless**: 621 unreadable source files; readable subset (5,643 files) archived. Retained in full. |
| `/Users/taha/Documents/Attic` (6 MB) | Brand assets explicitly out of removal scope; 25 dataless files; readable subset archived; directory retained |
| `/Users/taha/.codex/worktrees/*` (35 MB) | Snapshotted, not deleted (old lineage, cheap, referenced by old worktree registrations) |
| `/Applications/*.app` (incl. former owner's `com.emanueledipietro.Attic`), user application data | Explicitly out of scope |
| `/private/tmp/attic-*` (~3.5 GB), `~/Library/Developer/Xcode/DerivedData/Attic-*` (411 MB), live `AtticPERFA1Final` preview | Explicitly out of scope: `/tmp` preview apps, shared DerivedData, active reviewer evidence (`/tmp/deepseek-batch1-*`) |

## 5. Git layout restructuring (promotion to standalone/main)

The former topology was: current checkout was a **linked worktree** whose real
metadata lived in `/Users/taha/Developer/attic-recovery-20260907/.git`. Because the
host checkout was itself retired, the documented-safe restructuring chosen was
"promote current checkout by moving the common store into it" — performed
transactionally:

1. Archived the complete common `.git` and the per-worktree registration
   (index, HEAD, reflog) plus the host top-level metadata.
2. Saved the `.git` pointer file, then `rm`'d it and **moved** the common `.git`
   directory into `/Users/taha/Developer/attic-task-panels-v2/.git`.
3. Removed the now-stale `worktrees/attic-task-panels-v2` registration.
4. Restored the per-worktree index, `HEAD` (`ref: refs/heads/codex/attic-task-panels-v2`),
   and reflog so the working tree's dirty state stayed exactly as it was.
5. Verified: `git-dir == common-dir == .git`, no `commondir`, no alternates, no
   stray refs, branch and 116 refs intact, fsck clean, and source bytes unchanged.

No live Git internals were hand-edited beyond that registration removal, which is
the documented `worktree` promotion sequence. The alternative (keeping the old host
as a metadata host) was not needed because every writer was terminal and the move
verified first-try.

## 6. Verification evidence

- **Refs:** all 116 live refs confirmed present in the final all-refs bundle
  (`manifests/refs-FINAL-before-mutation.txt`).
- **Source before/after:** 452-file SHA-256 baseline captured pre-mutation;
  post-cleanup diff contained only the intentionally replaced `.git` pointer file.
- **Worktree snapshots:** each of the 7 retired worktrees re-hashed against its
  archive immediately before removal — all matched.
- **Deleted branches:** each tip resolves in the bundle; `git cherry` uniqueness
  re-verified live at deletion (0 for all 18).
- **Archive:** `git bundle verify` on 4 bundles, `verify-pack` on 2 packs, and a
  full restore inspection (fresh bare repo from the metadata copy → 116 refs,
  fsck clean; `fetch` from the unreachable bundle → 45/45 commits; xcresult re-read).
- **Git health after promotion:** `status`, `log`, `diff`, `show`, `worktree
  add/remove` tested; 160 dirty entries preserved.
- **Disk:** measured `df` before (6.5 GB free) and after (22 GB free) ≈ 15.5 GB
  reclaimed, consistent with ~13.5 GB of retired `.build` plus ~3.3 GB of retired
  worktree source and Git copies.

## 7. Incidental finding, disclosed

While testing the restructure procedure in a sandbox, a `cd` failed and two test
refs were accidentally created in the **real** repository at 11:17:45:
`refs/heads/other-branch` (at `ae6418c`) and `refs/synara/checkpoints/test`
(at `ae6418c`). They were detected by ref-count comparison, confirmed as mine via
their reflogs/mtimes, and removed with `git update-ref -d`. Branch count returned
to the expected 19 before any other mutation, and no other repository state was
affected. Final state contains neither ref.

## 8. Limitations

- iCloud-dataless content described in §4 is positively **blocked**, not archived.
  Those paths were retained in place; do not treat them as empty. Completing their
  archival needs the files materialized (e.g. by opening them in Finder/iCloud)
  before any future removal.
- Sizes are `du`/`df` snapshots; APFS clones and shared blocks can make apparent
  sizes differ from marginal savings.
- Remote state was never fetched, so no claim is made about remote branches.
- This report covers local cleanup only; it is not a code review or a release claim.
