# Original motion refinement

The user rejected the experimental funnel on September 12, 2026, reported
flicker during a two-finger dismissal, and chose the original motion with light
polish. Earlier funnel checks did not establish visual acceptance and do not
validate this replacement.

## Current behavior

The original live Core Animation transform is restored. Window movement and
collapse use matching easing curves, retaining the original 0.24-second reveal
and 0.22-second dismissal. Subpanel row and composer transitions remain brief
(0.18–0.20 seconds) and respect Reduce Motion.

The experimental renderer, capture cache, display link, preference, and picker
are removed. No snapshot capture, custom GPU buffers, per-frame SwiftUI layout,
or custom animation render loop remains in the main panel path.

## Reproduced swipe defect

The original path also had a continuity defect: when changed and ended scroll
events arrive in one run-loop turn, stopping the interactive motion sampled
Core Animation's stale presentation tree. The regression expected scale
0.718571 but observed 1.0, a snap back to full size. The presentation tree is
now consulted only while a timed collapse animation is active. Direct finger
updates use the current model transform; interrupted timed animations still
freeze their visible transform.

This is a demonstrated correction, not proof that every visual artifact in
the rejected funnel had the same cause. The user's physical swipe and motion
preference still need confirmation on the replacement preview.

## Baseline and recovery

Worktree: `/Users/taha/Developer/attic-funnel-redo`  
Branch: `codex/attic-funnel-redo`  
Git baseline: `ae6418c1af690e29d15a20344cdb9765a23d3f85`, plus the completed
uncommitted subpanel candidate and these motion refinements.

The completed subpanel worktree remains unchanged at
`/Users/taha/Developer/attic-hover-pinned-subtasks`. Its starting input is saved
under `.build/funnel-redo-baseline/`. The rejected funnel source and previous
verification report are archived under `.build/rejected-funnel-20260912/`.
Previous result bundles and the older rejected animation worktree are preserved.
Nothing was committed, merged, pushed, or installed over the official app.
No task or note data was copied or reset.

## Verification

- `.build/OriginalSwipeRepro.xcresult`: new native regression fails with the
  original presentation reader (1.0 versus expected 0.718571).
- `.build/OriginalSwipeFixed.xcresult`: the same regression passes after the fix.
- Project regeneration/repeatability and `git diff --check` passed.
- `.build/OriginalMotionFinal.xcresult`: 155 tests passed, zero failures/skips
  and no runtime warnings. This includes the swipe-release regression, actual
  controller cancellation and 12 completed dismissals, main-panel geometry,
  subpanel controllers, surfaces, and hit testing. The test-only compositor
  screenshot helper emits a deprecated-API compiler warning.
- Native frames at four finger positions were inspected; the panel remains
  readable, upright, and attached to its corner. Native and hosting bounds stay
  fixed during the gesture. The controller probe checks that committed motion
  never grows back toward full size and that the native window orders out.
- The signed replacement was launched and inspected through native computer
  use as Attic Motion Preview (PID 65710 at verification). The full-size resting
  panel and controls were visible. Physical two-finger feel remains user UAT.
- The previous three subpanel UI tests passed with the unchanged small-panel
  motion. They were not rerun for the replacement main-panel path; current
  native controller tests and installed-preview inspection cover this revision.

The 12-cycle native controller probe ran for 6.387 seconds, consuming 0.739
process CPU seconds (11.57% of one core during repeated motion). Resident memory
started at 99.375 MiB and ended at 86.219 MiB, with no accumulation across cycles.
The following one-second idle interval consumed 0.012818 CPU seconds. This is a
test-host measurement, excludes WindowServer/GPU energy, and is not directly
comparable to the former renderer-only probe. Raw results and native frames are
in `.build/Preview/PreviewState/OriginalMotionFrames/`.

## Isolated preview

Display name: **Attic Motion Preview**  
Bundle identifier: `com.taha.Attic.funnel.redo`  
Executable: `AtticFunnelRedo`  
Build location: `.build/Preview/Build/Products/Local/AtticFunnelRedo.app`

The isolated identity is retained to preserve its local store. This is an
`ATTIC_LOCAL_ONLY` build with sandbox/network entitlements and no CloudKit/APNs.
Its manifest, executable hash, signature, and entitlements are in
`.build/Preview/PreviewState/`. Physical gesture feel, accessibility UAT,
whole-day energy use, other Macs, and production readiness remain separate
from automated source/native checks.

Verified executable SHA-256:
`f27a324a061e3ac4cbce17c6af9d81e8c8a2c4c3728d75d4f86f796293f4536a`.
