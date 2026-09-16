# Attic Worktree & Branch Cleanup Inventory — 2026-09-15

READ-ONLY investigation. No branch, worktree, ref, process, or file was modified,
deleted, staged, committed, fetched, or reset while producing this report. Every
deletion/archive item below is a **proposal requiring explicit user approval**, not
an authorization. The active Opus agent (`agent-2bd66334267fdaac75b6f3310aa22dd9`)
and one further live `xcodebuild` were running against the current checkout during
this scan and were left untouched.

- **Inventory timestamp:** 2026-09-15, 10:02–10:38 BST (Europe/London)
- **Inventory root:** `/Users/taha/Developer/attic-task-panels-v2`
- **Recheck caveat:** the current checkout is being actively edited. Its dirty
  counts moved from 153 (10:02) while this scan ran (a live `xcodebuild
  build-for-testing` started 10:25 against it). Any decision touching this
  checkout must re-verify at execution time. No other checkout is live-edited.
- **Disk pressure context:** `/System/Volumes/Data` reported 100% → 97% used
  (2.2 GB → 15 GB free) during the scan; sizes below are approximate.

---

## 1. What "latest complete" means, and what the evidence establishes

Four separate dimensions were tested; they do **not** agree on a single winner:

| Dimension | Definition | Where the evidence points |
|---|---|---|
| Latest committed line | Newest commit reachable on a branch | `codex/attic-task-panels-v2` @ `ae6418c` (2026-09-11 18:42) |
| Latest actual source state | Newest on-disk work, committed or dirty | current checkout `/Users/taha/Developer/attic-task-panels-v2` (edited 2026-09-15 10:36+) |
| Latest accepted-verification state | Newest state with passing evidence and no open regressions | `attic-funnel-redo` dirty (155 tests pass, Sep 12 06:46) and current checkout (DeepAudit batch1) in parallel; neither has physical-UAT sign-off |
| Old-lineage completeness | Content of the retired `Documents/Codex/.../Attic` repository | Largely re-homed: 13/15 local branch tips and 3/9 remote-tracking tips exist in the new repository; the absent six are pre-Aug-27 audit/feature heads whose work was squashed into `b8bd355` (old main), which is an ancestor of current HEAD |

**Conclusion:** the current checkout at branch `codex/attic-task-panels-v2` is the
only defensible *authoritative* workspace — it carries the newest source, the only
active Synara writers, and a full-tree checkpoint (`7843b988`, 2026-09-15
10:03:50) whose 445 tracked+untracked files hash-identical to the live worktree at
10:37. "Latest complete" in the sense of *all unique work consolidated, verified,
and free of uncommitted risk* does **not** yet exist anywhere; the closest
candidates are the current checkout (uncommitted, in flight) and
`attic-funnel-redo` (verified but a side experiment). Branch HEAD age alone
correctly cannot establish this, and does not here.

---

## 2. Repository topology (git metadata first)

All nine `/Users/taha/Developer` worktrees share **one** repository:

- Common dir: `/Users/taha/Developer/attic-recovery-20260907/.git`
- Origin: `https://github.com/TesterPen0812/Attic.git`
- Fetch refspec is narrow: only `refs/heads/codex/attic-local-baseline` is
  tracked; only one remote-tracking ref exists, `origin/codex/attic-local-baseline`
  @ `5a2b7ec` (2026-08-31). All other remote-tracking content is stale or absent —
  no fetch was performed.
- 19 local branches, 9 registered worktrees, 0 locked, 0 prunable, no
  `index.lock` anywhere, nothing staged in any checkout.
- 77 `refs/synara/checkpoints/*` refs (22 agent identities) exist **only** in this
  repository; they are the recovery net for the current dirty tree.

A **second, older repository** exists at
`/Users/taha/Documents/Codex/2026-07-19/d/work/Attic/.git` (same origin URL). Its
loose files are iCloud-dataless (`compressed,dataless`), so reads time out; only
its `packed-refs` (readable) and object pack (351 MB/232 MB pack, readable) could
be inspected. Its registered worktrees live under `/Users/taha/.codex/worktrees/`.
`git bundle list-heads` on
`.../d/backups/Attic-canvas-ink-8063d92-20260827.bundle` confirms the bundle holds
`backup/canvas-ink-luna-20260827` @ `8063d92c`.

The new repository contains the old lineage: `b8bd355` (old `main`/`origin/main`)
is an ancestor of current HEAD, and old local `main` `4c131e6` (squircle, Aug 26)
plus its two parents are also present, with 0 commits in `4c131e6` that are missing
from `ae6418c`. The only old-repo refs whose commits are **not** present are
`synara/adjust-panel-squircle-sizing` (`f16cf351`, no commit object), 
`synara/adjust-panel-translucency` (`b63dfac4`, absent) and stale remote-tracking
audit/feature refs (`dc2415de`, `5149a691`, `9db180d9`, `31769942`, `455353846`,
`abb7e550`, all absent; all pre-2026-08-27 lineage).

### 2.1 Developer-cluster worktrees (shared repository)

| Path | Branch @ HEAD | HEAD date | Dirty (M / ??) | Approx size (src / build) |
|---|---|---|---|---|
| `attic-task-panels-v2` | `codex/attic-task-panels-v2` @ `ae6418c` | 2026-09-11 18:42 | 67 / 87 | ~65 MB / 3.9 GB |
| `attic-recovery-20260907` (main wktree) | `codex/attic-readable-themes-20260908` @ `bd5e246` | 2026-09-08 04:39 | 0 / 0 | ~73 MB / 3.2 GB |
| `attic-animation-devin-local` | `codex/attic-animation-devin-local` @ `25e36b3` | 2026-09-11 18:07 | 9 / 0 | ~7 MB / none |
| `attic-animation-fable-51` | `codex/attic-animation-fable-51` @ `23ede87` | 2026-09-11 02:52 | 0 / 0 | ~7 MB / none |
| `attic-clear-reading-experiment` | `codex/attic-clear-reading-experiment` @ `da31f27` | 2026-09-08 02:44 | 5 / 0 | ~2 MB / 1 MB |
| `attic-funnel-redo` | `codex/attic-funnel-redo` @ `ae6418c` | 2026-09-11 18:42 | 14 / 3 | ~7 MB / 1.0 GB |
| `attic-hover-pinned-subtasks` | `codex/attic-hover-pinned-subtasks` @ `ae6418c` | 2026-09-11 18:42 | 13 / 2 | ~7 MB / 5.9 GB |
| `attic-scroll-under-controls` | `codex/attic-mcp-subtasks-composer` @ `b109b17` | 2026-09-09 22:23 | 21 / 3 | ~3 MB / 4.0 GB |
| `attic-ux-refinement` | `codex/attic-ux-refinement` @ `ae6418c` | 2026-09-11 18:42 | 45 / 13 | ~10 MB / 1.8 GB |

Total ≈ 20 GB, of which ≈ 19.7 GB is disposable `.build` output
(`DerivedData`, `batch*`, UI-test builds). The shared object store is only ~71 MB.
`.build` is gitignored and contains no source of record.

### 2.2 Old-cluster checkouts

| Path | Repo relation | State | Approx size |
|---|---|---|---|
| `/Users/taha/Documents/Codex/2026-07-19/d/work/Attic` | old repo main checkout (dataless git files) | source files readable, all 12 inspected `Attic`-cluster worktrees registered; 440 MB total incl. 328 MB `.git` | 440 MB |
| `/Users/taha/Documents/Codex/2026-07-19/d/work/Attic-native-liquid-glass-preview` | old repo linked worktree (its gitdir file is dataless) | source present, 347 MB | 347 MB |
| `/Users/taha/.codex/worktrees/attic-*` (18 dirs) + `de8b`/`e183`/`f657` | old repo linked worktrees | small source snapshots (1–3 MB each, 35 MB total): `attic-adaptive-themes`, `-comprehensive-{audit-fixes,canvas,notes,panel,themes-integration}`, `-live-stable`, `-main-audit-review`, `-main-deep-audit`, `-mcp-notes`, `-notes-attachments-final`, `-p1-canvas-zoom`, `-p2-window-docking`, `-p3-visual-polish`, `-p6-settings-refine`, `-settings-premium`, `-siri-shell`, `-tasks-glass-modes`; `de8b`/`e183`/`f657` are nested `Attic/` checkouts | 35 MB |
| `/Users/taha/Documents/Codex/2026-07-19/d/backups/Attic-canvas-ink-8063d92-20260827.bundle` | old-repo bundle | ref `backup/canvas-ink-luna-20260827` @ `8063d92c` (present in new repo) | 9.3 MB |
| `/Users/taha/Documents/Attic` | separate minimal repo, `brand/` assets + `codex/turn-diffs` refs only | no worktree files besides brand logos; 6 MB | 6 MB |

The `attic-comprehensive-themes-integration` directory is **not** an old-repo
worktree anymore: it contains a standalone nested repository whose origin points
at `/Users/taha/.codex/worktrees/attic-comprehensive-audit-fixes`, with 233
commits and the same root `4c8f480`. Only 3 of its commits are unique to the new
object store: `994b447` (strengthen clear foreground contrast), `8b8388c`
(trackpad direction correction), `71c24a3` (clear foreground halo), all Sep 1.

### 2.3 Other discovered Attic-adjacent dirs

- `/Users/taha/Documents/Codex/2026-09-12/attic-animation-orchestration` (92 KB,
  `subpanel-audit-reports/`), `/Users/taha/Documents/Codex/2026-09-14/attic-coordinator`
  (0 B), `/Users/taha/Documents/Codex/2026-07-19/ca` (0 B) — agent scratch dirs,
  no repository.
- `synara-concurrency-five` is the Synara product repo, unrelated to Attic; not
  inventoried further.
- Installed apps: `/Applications/Attic.app` (`com.emanueledipietro.Attic`, old
  owner — untouched), `/Applications/Attic Daily.app` (`com.taha.Attic`),
  `/Applications/Attic Notes Local.app` (`com.qasimwaseem363.AtticNotesLocal`).
- One live preview process: `/private/tmp/attic-perfa1-final-dd/.../AtticPERFA1Final.app`
  (started Sep 14 22:23, container `com.taha.Attic.perfa1final`), not bound to any
  worktree working directory.
- Four Xcode `DerivedData/Attic-*` dirs (≈411 MB) and ≈3.5 GB of `/private/tmp/attic-*`
  build/test scratch (some referenced by the live `xcodebuild`). All are build
  artifacts, not source.

---

## 3. Branch topology and unique-commit analysis

Merge base for everything current is `b8bd355` (old main). `ae6418c` is 248
commits past it. Key branch relations to `ae6418c` (left = commits in ae6418c not
in branch, right = branch commits not in ae6418c):

| Branch | Commits ahead of `ae6418c` | Patch-equivalent after `git cherry` | Verdict |
|---|---|---|---|
| `codex/attic-animation-fable-51` (`23ede87`) | 0 | 0 | Fully contained |
| `codex/attic-mcp-subtasks-composer` (`b109b17`) | 0 | 0 | Fully contained |
| `codex/attic-scroll-under-controls` (`2b5a066`) | 0 | 0 | Fully contained |
| `codex/attic-readable-themes-20260908` (`bd5e246`) | 0 | 0 | Fully contained |
| `codex/attic-local-baseline` (`5a2b7ec`) | 0 | 0 | Fully contained (= only tracked remote) |
| `codex/attic-recovery-20260907` (`2255f10`) | 0 | 0 | Fully contained |
| `codex/attic-refinement-20260908`, `-theme-review-20260908` (`9a9f7dd`) | 0 | 0 | Fully contained |
| `codex/attic-canvas-input-20260908` (`78e3fb5`) | 9 | 0 | Re-landed (subjects match `970c0c2`…`a085ac3`) |
| `codex/attic-gradient-settings-20260908` (`a191cc9`) | 8 | 0 | Re-landed (matches `62085f5`…`0613ba4`) |
| `codex/attic-motion-20260908` (`f211d3d`) | 4 | 0 | Re-landed (matches `df81e39`…`5a9d9b8`) |
| `codex/attic-notes-layout-20260908` (`a20ab11`) | 3 | 0 | Re-landed (matches `633c734`…`834418f`) |
| `codex/attic-readable-surfaces-20260908` (`3948658`) | 1 | 0 | Re-landed (matches `112b528`) |
| **`codex/attic-animation-devin-local`** (`25e36b3`) | 1 new commit + 9 uncommitted files | 1 | **Unique work** |
| **`codex/attic-clear-reading-experiment`** (`da31f27`) | 5 | 5 | **Unique work (experiment)** |

Unreachable-but-present commits in the new repository (`git fsck`): 28 total — 22
are Synara turn checkpoints; 6 are real work:

- `3915af7` Settings redesign foundation (below), `950d6a1` its design brief +
  premium-reference PNG (2026-08-27).
- A chain off `23ede87`: `1ca2fe2` (DevinGenieAnimationHandoff + corner-pull
  sketch, Sep 11 04:01) → `6789d34` (corner-pulled genie transition:
  `PanelGenieGeometry.swift`, `PanelGeniePresentation.swift`, 380+380 lines, Sep 11
  03:38) → `fb00756` (test fix) → `7ad978d` (OSLog import). Not reachable from any
  ref; only the blob objects survive. The devin-local worktree instead carries a
  different, uncommitted `PanelFunnelAnimation.swift` (497180fb, not in any ref).

### 3.1 Settings foundation commit `3915af7` (explicit question)

- `3915af7` = `feat(macOS): redesign Settings experience`, 2026-08-27 08:07,
  16 files, +1615/−776. Its child `950d6a1` adds `Design/SETTINGS-REDESIGN-BRIEF.md`
  and `Design/SettingsPremiumReference.png`.
- **No ref in the new repository contains it** (only unreachable objects + reflog
  survive). `ae6418c..3915af7` = 2 commits; `3915af7..ae6418c` = 248.
- However, the new lineage independently rebuilt the same foundation: `7c522c0`
  `feat: refine premium local-only settings` (Aug 30, ancestor of `ae6418c`) adds
  the same `SettingsSection`, `SettingsComponents`, `GeneralSettingsView`, etc.,
  then evolved further. Direct component comparison (`3915af7` vs tree):
  `AtticTheme`/`SettingsView`/`SettingsSection` differ; `GeneralSettingsView.swift`
  is byte-identical to the current worktree; `SyncSettingsView.swift` exists only in
  `3915af7` and was later deliberately removed (local-only contract).
  `SettingsPresentationTests.swift` evolved 6/9-line changes through `7c522c0`
  and +182 lines later.
- **Unique work remaining at risk from `3915af7`:** the two design documents
  (`SETTINGS-REDESIGN-BRIEF.md`, `SettingsPremiumReference.png`) — present as blobs
  in the new odb but on no ref, and physically present only in
  `/Users/taha/.codex/worktrees/attic-settings-premium/Design/` (byte-identical to
  `950d6a1`). The Settings *code* foundation is not unique; it was superseded by
  `7c522c0`. `SyncSettingsView` deletion was intentional under the local-only
  contract. So: **do not expend `3915af7` blindly, but its only non-reproduced
  artifact is the design brief + reference PNG.**

---

## 4. Unique uncommitted work per checkout (files at risk)

Measured by content hash against the shared object store and all refs reachable in
it. `FS-only` = bytes exist nowhere in the object database; `dangling` = object in
odb but on no ref; `in-refs` = reachable from a branch/checkpoint.

| Checkout | Dirty files | identical to current | reachable from refs | dangling in odb | **FS-only (highest risk)** |
|---|---|---|---|---|---|
| `attic-task-panels-v2` | 316 (67 M + 249 incl. ignored) | 316 | 0 | 0 | 0 (full-tree checkpoint `7843b988` @ 10:03 matched at 10:37) |
| `attic-animation-devin-local` | 9 | 0 | 0 | 0 | **9** |
| `attic-clear-reading-experiment` | 5 | 0 | 0 | 0 | **5** |
| `attic-funnel-redo` | 17 | 3 | 0 | 5 | **9** |
| `attic-hover-pinned-subtasks` | 15 | 2 | 0 | 5 | **8** |
| `attic-ux-refinement` | 59 | 15 | 3 | 41 | 0 (41 dangling, on no ref) |
| `attic-scroll-under-controls` | 24 | 10 | 14 | 0 | 0 |
| `attic-recovery-20260907`, `attic-animation-fable-51` | 0 | – | – | – | 0 |

FS-only files by checkout:

- **devin-local (9):** `AppSettings.swift`, `PanelSettingsView.swift`,
  `AtticPanel.swift`, `AtticPanelController.swift`, `PanelFunnelAnimation.swift`,
  `AppSettingsTests.swift`, `PanelFunnelAnimationTests.swift`,
  `PanelGeometryTests.swift`, `AtticUITests.swift`.
- **clear-reading-experiment (5):** `AtticTheme.swift`, `AtticPanelView.swift`,
  `NotesPanelContent.swift`, `TaskRowView.swift`, `TaskSectionView.swift`.
- **funnel-redo (9 FS-only + 5 dangling):** project file, `AtticStyle.swift`,
  `SubtaskPanelLayout.swift`, `SubtaskPanelContent.swift`, `AtticPanel.swift`,
  `AtticPanelController.swift`, `SubtaskPanelController.swift`,
  `PanelGeometryTests.swift`, `SubtaskPanelTests.swift`; dangling:
  `TaskFamilyView.swift`, `SubtaskPanelControllerTests.swift`,
  `SubtaskHoverPinnedUITests.swift`, `PanelSurfaceHostingView.swift`,
  `PanelSurfaceHostingViewTests.swift`. Its docs (`FunnelRedoVerification.md`,
  hover ledger) are already in refs.
- **hover-pinned-subtasks (8 FS-only + 5 dangling):** same shape as funnel-redo
  minus `AtticPanelController.swift`. Its dirty state is roughly 2.5 h **older**
  than funnel-redo's (mtimes Sep 12 00:08–00:51 vs 06:01–06:46) and funnel-redo's
  versions of the three differing files are the later ones.
- **ux-refinement (41 dangling):** includes `TaskStore.swift`, `PanelGeometry.swift`,
  `AtticPanelView.swift`, `AtticPanelController.swift`, Canvas files, tests — later
  than `f3ec4a3` (which captured 32 of its files) but on no ref. The other 15+3 are
  already identical to current or in refs.

## 5. "Approved" states and verification evidence

- `attic-funnel-redo` `Docs/FunnelRedoVerification.md`: user rejected the
  experimental funnel Sep 12; original motion restored with a reproduced swipe
  fix; `OriginalMotionFinal.xcresult` = 155 pass/0 fail; physical swipe UAT
  remained pending at that time.
- `attic-hover-pinned-subtasks` ledger: 635 pass/1 skip; physical-pointer,
  VoiceOver, multi-display, and non-class UI suites explicitly unverified.
- Current checkout: `Docs/DeepAudit-Consolidated-2026-09-15.md` (62 raw → 55 unique
  findings) and `Docs/DeepAudit-Batch1-Implementation.md` (REVIEW_READY, native
  evidence PENDING). A 497-test windowless run passed earlier Sep 14; a live
  `xcodebuild build-for-testing` was running at 10:25.
- `3915af7` has no surviving build/test evidence and is not reachable from any ref.
- Tag `attic-daily-1-8b03586df79c` (`8b03586`, Sep 9) marks the daily-app tooling.

## 6. Keep / consolidate / archive / delete-candidate table

Deletion candidates require user approval; nothing here authorizes a destructive
action. "Archive" = preserve as bundle/tag before removing the working directory.

| Item | Class | Evidence | Uncertainty |
|---|---|---|---|
| `attic-task-panels-v2` (branch `codex/attic-task-panels-v2` @ `ae6418c`) | **KEEP — authoritative** | Newest source; live agents (`agent-2bd6633`, `agent-ac60ed0`, `-3d1a164a`, `-12627ff2`, `-577fd176`, `-f0bdc87e`, `-bdf8c2a2`); checkpoint `7843b988` byte-matches worktree at 10:37 | Active edits + running build; recheck before any action |
| `docs` full-tree Synara checkpoints (`refs/synara/checkpoints/*`, 77 refs) | **KEEP** | Only safety net for 316 dirty files; `5f0ba85`/`7843b988`/`6625994` capture untracked work byte-exact | Ref pruning risk until a durable commit/bundle exists |
| Branch `codex/attic-task-panels-v2` and all contained branches (`local-baseline`, `recovery-20260907`, `refinement-*`, `theme-review-*`, `scroll-under-controls`, `mcp-subtasks-composer`, `readable-themes-*`, `animation-fable-51`) | **KEEP (cheap) or consolidate** | 0 unique commits each; refs are nearly free | Remote-tracking refs are stale — do not treat as authoritative |
| Re-landed branches (`canvas-input`, `gradient-settings`, `motion`, `notes-layout`, `readable-surfaces` @ Sep 8 `78e3fb5`…`a191cc9`) | **DELETE-CANDIDATE (local refs only)** | `git cherry` = 0 unique; subjects map 1:1 to current-lineage commits | Old commit objects would become unreachable if refs removed |
| `attic-recovery-20260907` main worktree | **KEEP** (it hosts the shared `.git`; it is the repo's main checkout) | Contains the common dir; branch `bd5e246` contained | Its 3.2 GB `.build` is disposable |
| `attic-animation-devin-local` (branch + 9 FS-only files) | **CONSOLIDATE, then archive** | Unique uncommitted funnel/animation work on no ref; supersedes the unreachable `6789d34` genie chain direction | Overlaps funnel-redo/hover-pinned; needs a human decision which animation direction wins |
| Unreachable genie chain (`6789d34`, `fb00756`, `7ad978d`, `1ca2fe2`, `950d6a1`, `3915af7`) | **ARCHIVE as refs or bundle** | Objects exist; on no ref; gc could prune | Only real unique content: genie geometry files + `DevinGenieAnimationHandoff.md` + settings design brief/PNG |
| `attic-funnel-redo` | **CONSOLIDATE / KEEP for now** | Newest hover/pinned line (Sep 12 06:46); 155-test pass; but its dirty files are FS-only or dangling | Same UI feature as hover-pinned-subtasks; user rejected funnel visuals, so keep the *motion fix*, not necessarily the files |
| `attic-hover-pinned-subtasks` | **ARCHIVE-CANDIDATE (after diff vs funnel-redo)** | Strictly older than funnel-redo for the 3 differing files; ledger 635 pass | Has unique dangling tests/docs, verify before removing |
| `attic-ux-refinement` (45 M + 13 ??) | **CONSOLIDATE — do not delete** | 41 files, incl. `TaskStore.swift`/`PanelGeometry.swift`/Canvas work, are *later* than `f3ec4a3` and on no ref | Its dirty copy of `TaskPanelV2Requirements.md` is an *earlier* draft (Sol-medium process text) that the current checkout's copy supersedes; the ux draft blob is still on no ref |
| `attic-clear-reading-experiment` (5 FS-only) | **CONSOLIDATE or EXPERIMENT-ARCHIVE** | 5 unique commits (Clear-backing experiment) + 5 unique dirty files | Experiment direction may be rejected; verify with user |
| `attic-scroll-under-controls` | **ARCHIVE-CANDIDATE** | 24 dirty files all preserved in refs (10 identical to current) | Its branch is contained in `ae6418c`; checkout itself may still be referenced by docs |
| `attic-animation-fable-51` | **ARCHIVE-CANDIDATE** | Clean, 0 dirty, head `23ede87` contained in `ae6418c` | Docs still cite it as the hover/pinned handoff source |
| `.build/` in every `/Users/taha/Developer` worktree (~19.7 GB) | **DELETE-CANDIDATE (build artifacts only)** | Gitignored; reproducible; source unaffected | One live `xcodebuild` writes to `/private/tmp`, not `.build`; `attic-task-panels-v2/.build` may still hold needed xcresults |
| `/private/tmp/attic-*` (~3.5 GB), four `DerivedData/Attic-*` (~411 MB) | **DELETE-CANDIDATE (artifacts)** | Build/test scratch; the Live preview app runs from `/tmp/attic-perfa1-final-dd` — quitting it first is a prerequisite | Live process holds `attic-perfa1-final-dd` open |
| Old repository `Documents/Codex/2026-07-19/d/work/Attic` + 2 satellite checkouts (787 MB) | **ARCHIVE-CANDIDATE (old lineage)** | 13/15 local branch tips contained in new repo; only `f16cf351`/`b63dfac4` commit objects absent; six absent remote-tracking tips map to pre-Aug-27 squashed work | iCloud dataless files make integrity verification partial |
| `.codex/worktrees` 18 dirs + `de8b/e183/f657` (35 MB) | **ARCHIVE-CANDIDATE (old lineage)** | Small; all but a handful of files resolve into the new odb; unique content is old Notes-attachment/MCP-era files already superseded | Unique blobs listed in §4 are the exception; do not remove before archiving them |
| `attic-comprehensive-themes-integration` nested repo (3 unique commits) | **ARCHIVE-CANDIDATE** | 233 commits; only `994b447`/`8b8388c`/`71c24a3` (Sep 1, clear-foreground fixes) absent from new repo | Small; cheap to bundle |
| `Design/` brief + `SettingsPremiumReference.png`, `DevinGenieAnimationHandoff.md`, ux-refinement's earlier `TaskPanelV2Requirements.md` draft | **KEEP / copy** | Unique docs on no ref / earlier variants | Requires explicit user choice on destination |

---

## 7. Recommendation for authoritative checkout/branch

1. **Authoritative workspace:** `/Users/taha/Developer/attic-task-panels-v2` on
   `codex/attic-task-panels-v2` @ `ae6418c`. It is the only place with live
   writers, the newest source, and a verified full-tree checkpoint.
2. **Authoritative recovery refs:** keep all `refs/synara/checkpoints/*` until the
   dirty tree is checkpointed durably (commit on a dedicated branch or a git
   bundle kept outside `.git`).
3. **Authoritative remote:** `origin` = `TesterPen0812/Attic`; only
   `codex/attic-local-baseline` is fetch-tracked. **Remote cleanup is out of
   scope** (see §9) — do not push/prune until the user says so.

## 8. Safe backup / checkpoint prerequisites (before any cleanup)

Ordered; every step is additive and reversible.

1. **Quiesce writers** (user decision; outside this read-only task): stop or
   finish the Opus agent and the `xcodebuild` against the current checkout.
2. **Freeze the current tree as content:** create a `git bundle` of a new
   checkpoint commit (or at minimum copy the three Synara checkpoint objects +
   loose odb) so the 316 dirty files survive independent of `.git` and of ref
   pruning. The `7843b988`/`5f0ba85` checkpoints already byte-match at 10:37.
3. **Create durable refs** for the six unreachable real commits
   (`3915af7`, `950d6a1`, `1ca2fe2`, `6789d34`, `fb00756`, `7ad978d`) under
   `refs/archive/...` or a bundle, *before* any `git gc --prune`.
4. **Create durable refs/branches** (or bundles) for the FS-only files in
   devin-local (9), clear-reading (5), funnel-redo (9+5 dangling), hover-pinned
   (8+5), ux-refinement (41 dangling) — e.g. temporary `archive/*` commits on
   each branch, or `git stash create` objects. Without this step those bytes can
   vanish with a single `rm`/`git clean`.
5. **Snapshot docs** that live on no ref: `Design/` brief + PNG,
   `DevinGenieAnimationHandoff.md`, ux-refinement's unique
   `TaskPanelV2Requirements.md` draft (its only copy on no ref).
6. **Archive the old lineage** into one bundle each: old `Documents/.../Attic`
   repo, `attic-comprehensive-themes-integration`, `.codex/worktrees` unique
   blobs, `Attic-canvas-ink` bundle (already a bundle), `Documents/Attic` brand
   refs.
7. **Verify archives**: `git bundle verify` + re-hash of FS-only files.
8. Only then remove build artifacts, stale worktrees, and re-landed local refs.

## 9. Proposed ordered cleanup plan (all steps user-approved first)

Phase A — consolidation (no deletions):
A1. Re-inventory the current checkout (it is live) and record new dirty counts.
A2. Checkpoint/commit or bundle the current dirty tree; tag the checkpoint.
A3. Create `archive/*` refs (or bundle) for the six unreachable commits and all
    FS-only/dangling files listed in §4 and §6.
A4. Decide the animation direction (devin-local funnel vs funnel-redo motion fix
    vs hover-pinned) with the user, then consolidate the winner onto a single
    branch.

Phase B — de-registration (requires approval, low risk):
B1. `git worktree remove` for clean, fully-contained checkouts:
    `attic-animation-fable-51`, then (after A3) `attic-scroll-under-controls`,
    `attic-clear-reading-experiment`, `attic-hover-pinned-subtasks`,
    `attic-funnel-redo`, `attic-animation-devin-local`, `attic-ux-refinement`.
    Removing a worktree does not delete its branch or its archived blobs.
B2. Delete re-landed local branch refs (`canvas-input`, `gradient-settings`,
    `motion`, `notes-layout`, `readable-surfaces`, and the duplicated
    20260908/theme-review names) only after confirming `git cherry` uniqueness = 0
    at that moment.

Phase C — disk reclamation (requires approval; artifacts only):
C1. Quit/stop the preview process, retire `/private/tmp/attic-*`,
    `DerivedData/Attic-*` — ~3.9 GB.
C2. Remove per-worktree `.build` directories — ~19.7 GB, of which the current
    checkout's 3.8 GB should be kept longest (test evidence inside).
C3. Only after verified bundles: remove old `Documents/.../Attic` checkout and
    `.codex/worktrees` dirs (≈822 MB combined).

Phase D — remote (out of current scope; listed for a separate decision):
D1. `origin/codex/attic-local-baseline` is the only tracked remote; no remote
    deletion, pruning, or pushes are proposed here.
D2. If remote cleanup is later requested: candidate remote branches would be the
    re-landed `codex/*` line plus old `audit/*` and `feature/notes-attachments-*`
    — but remote state was not fetched or verified, so this list is provisional
    and must not be acted on from local refs alone.

## 10. What must NOT happen yet

- No `git gc` / `git prune` in the new repository before §8 steps 2–4: six real
  commits and the design-artifact trees are currently unreachable and would be
  pruned.
- No `git clean` / `rm` in devin-local, clear-reading-experiment, funnel-redo,
  hover-pinned-subtasks, or ux-refinement: those hold bytes found nowhere else.
- No branch switching, reset, or stash in `attic-task-panels-v2` while the Opus
  agent and `xcodebuild` are live.
- No removal of `refs/synara/checkpoints/*` while the dirty tree lacks a durable
  checkpoint.
- No touching `/Applications/Attic.app` (former owner's bundle) or the
  `com.taha.Attic.perfa1final` container data without explicit approval.

---

## 11. Limitations and uncertainty

- Old-repo git files are iCloud-dataless; HEAD/config/worktree registration reads
  timed out. Branch mapping for the old cluster relies on readable `packed-refs`,
  worktree `gitdir` pointers, and content hashing — high but not complete
  confidence. Any commit whose object is absent (`f16cf351`, `b63dfac4`, and six
  pre-Aug-27 remote-tracking refs) could not be inspected.
- Remote-tracking refs are stale (last fetch Sep 7/11); **no remote state was
  verified** and remote cleanup is explicitly not proposed.
- The current checkout is live-edited; dirty counts and checkpoint equality were
  true at 10:37 BST, and a running `xcodebuild` began at 10:25. Recheck before
  acting.
- `git log --find-object` reachability excludes objects referenced only by
  dangling trees; FS-only classification used odb presence + ref walk, which is
  the strictest available read-only test.
- Sizes are `du` snapshots; APFS clones/shared blocks and the two repos sharing
  an origin mean apparent sizes overstate marginal disk savings.
- This report is a source/state inventory, not a code review or a claim that any
  branch is release-ready. No implementation behavior was assessed beyond what
  was necessary to identify preserved versus unique work.
