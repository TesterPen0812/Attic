# Main Attic panel: corner-pulled sheet animation

## Assignment

Implement the user's confirmed motion direction for the MAIN Attic panel hiding
and revealing. This is a separate task from subtask hover/pin presentation.
Use SWE-2, Max effort. The user explicitly requests your best work and unusually
strict quality expectations. That means careful implementation, objective
checks and honest visual evidence, not extra features or inflated claims.

Repository: https://github.com/TesterPen0812/Attic.git
Assigned branch: `codex/attic-genie-panel-animation`.
Base commit: `23ede879725c3042d371e26e8ed84e7ced1a9f5f` (Devin's subtask work).
The next handoff commit adds this brief and the user sketch. Start at the exact
handoff SHA supplied in the task message, in an isolated worktree on this branch.
Read AGENTS.md and claude.md. You own ONLY this animation branch. The subtask
branch, main, installed Daily and the original local worktree are not writable.
Keep subtask changes intact. No force pushes, PRs, merges, deployment, account
changes or destructive data operations. Commit and push this branch only.

## Confirmed visual intent

Inspect `Docs/References/main-panel-corner-pull-sketch.png`. The user confirmed:
Attic stretches and tapers toward a small upper-right point as it hides, like
a flexible sheet being pulled into that point. Opening reverses that motion.
This is NOT a uniform shrinking rectangle, ordinary slide, fade, card flip or
subtask opening animation. The sketch represents the deformation envelope, not
a literal white outline to draw. Preserve the actual Attic glass panel styling.

Motion should feel like one continuous coherent surface. The corner-facing part
leads into the anchor; the far edge follows along a smooth narrowing curved
funnel. The full panel silhouette and its content travel together. At rest,
pixel appearance, content positions, corner radius and window geometry must be
identical to the normal app. Opening unfurls smoothly from that same anchor.

Upper-right is the reference direction. Use the current configured dock corner
on the correct screen as the real destination, mirroring the geometry for the
other supported corners. Never suck a lower-left panel across the whole screen
toward upper-right. Do not target an arbitrary global-origin coordinate. Keep
the endpoint inside the usable display and account for safe areas/menu bar,
Dock, Retina scaling, different display origins and display removal.

## Strict quality bar

1. Implement a real nonlinear sheet/funnel deformation, not a scale animation
   merely renamed genie. Compare sampled outline geometry at 0, 25, 50, 75 and
   100 percent: intermediate states must visibly taper toward the corner, while
   the far edge follows a continuous curve. No triangle-fold, self-intersection,
   inverted mesh, seams, clipping, torn text, rectangular backing or afterimage.
2. Use one deterministic progress-driven motion model for show and hide, with
   named bounded tunables. A starting timing budget is approximately 280–380 ms
   hiding and 320–420 ms revealing; tune for perceived quality, not rigid numbers.
   Avoid a long flourish, excessive overshoot, bounce or elastic wobbling.
3. Rapid reversal must continue from the currently visible presentation state,
   not jump to an endpoint. Handle show-hide-show, repeated hotkeys, hover entry,
   explicit hide, click-away and interrupted gestures. A stale completion must
   never hide a newly shown window or leave an invisible window blocking input.
4. Preserve the existing transactional hide boundary: a failed draft flush must
   reject hiding before destructive presentation changes. Preserve note/canvas
   interaction cancellation and exactly-once completion ownership. Do not alter
   task data, undo state or save semantics to make animation convenient.
5. Native content layout stays stable; avoid SwiftUI body/layout churn, repeated
   view recreation, full-window resize per frame and allocation-heavy drawing.
   Inspect the existing live-layer path first. If a temporary snapshot/mesh is
   necessary for genuine nonlinear warping, justify that choice and implement
   clean capture-to-live handoff, correct backing scale, transient-only lifetime,
   no black glass/blank snapshot, no stale content, and no desktop capture/TCC.
   Use public APIs only; do not use private WindowServer or Dock genie APIs.
6. No new dependencies unless there is a demonstrated necessity. GPU work must
   stop at completion/cancel/deinit; no idle display link or render loop. Reuse
   resources sensibly. No uncapped timers, event-monitor leaks or retain cycles.
   Don't make the machine hot for a small window transition.
7. Reduced Motion must use a quiet non-deforming immediate or short restrained
   alternative, not the full funnel at lower speed. Respect Reduce Transparency
   and existing light/dark/theme/high-contrast rendering. Changing accessibility
   preferences mid-transition must end in a coherent usable state.
8. Keep normal hit testing, keyboard focus and window activation correct at rest.
   Suppress interaction with temporary warped content only for the bounded
   transition; restore it on completion and cancellation. Do not steal focus when
   a non-activating hover reveal is intended. No orphan overlay after app hide,
   app quit, screen removal, window resize or presentation failure.
9. Independent pinned subtask windows must NOT be warped, hidden or repositioned
   when the main panel hides. Preserve transient subtask cleanup at the correct
   lifecycle boundary. The subtask controller's mainPanelDidHide call must still
   execute on a completed hide, not on a canceled hide.
10. Keep drag, resize, corner docking, live swipe/throw and normal panel reveal
    behavior functional. Test at minimum/maximum supported panel sizes and every
    corner. Never persist a warped/transitional frame as the user's saved size.

## Grounding and likely integration points

Inspect `Attic/Window/AtticPanelController.swift`: show, animateShow, requestHide,
animatePanel, stopPanelMotion and visibilityTransition generation/completion
barriers. It currently animates fixed-size native frames and a live subtree
collapse through contentContainer. Find `AtticPanelContentContainer`,
`PanelCollapseGeometry` and existing tests before selecting an implementation.
Inspect swipe/docking paths and callers rather than replacing a single method
and assuming all visibility transitions are covered. Make the smallest coherent
change, with a clear ownership boundary between geometry, rendering and lifecycle.

The baseline subtask code is being built locally in parallel. Do not rewrite it
or revert it. If a baseline compile issue prevents your check, report the exact
error and a minimal necessary fix, separate from animation behavior. Do not
blindly incorporate changes from another branch during execution.

## Verification required before claiming completion

- Unit tests for pure deformation geometry at endpoints and sampled intermediate
  values, all corners, sizes and display origins. Assert finite bounded values,
  continuity and monotonic progress toward the selected anchor; invalid inputs
  must fail safely. Add real regression tests for reversal/generation and cleanup,
  not tests that simply restate implementation constants.
- Regenerate project inputs and run project generation verification when needed.
  Run relevant existing motion/window/subtask tests and script tests. Record exact
  commands, versions, outcomes, failures and skipped/unavailable checks.
- On macOS: compile the local-only target, run native tests, launch a uniquely
  named sandbox-isolated preview, capture a real show/hide recording and useful
  intermediate frames, review them yourself against the sketch and iterate.
  Inspect fresh launch, repeated/reversed transitions, all four corners, reduced
  motion, light/dark, pinned subtask survival, and draft-save failure. Capture
  actual frame pacing with available Instruments/signposts or equivalent evidence:
  aim for smooth display refresh with no visible dropped-frame cluster and no
  unexplained main-thread stall over a frame budget. Report hardware/display and
  measurements; do not manufacture a 60/120 fps assertion from source inspection.
- Cloud Ubuntu cannot prove AppKit rendering or macOS frame pacing. If no native
  environment is available, finish implementation and available checks, supply
  test/recording instructions and explicitly mark native build/UI/performance
  UNRUN. Do not substitute a browser animation video as native visual evidence.
- Review the final diff for scope, platform availability and memory/lifecycle
  hazards. Deliver exact commit, concise implementation rationale, objective
  acceptance results and remaining UAT. Preserve the current macOS-first,
  ATTIC_LOCAL_ONLY, duplicate-safe/local-store contract. No CloudKit/APNs/iPhone,
  production signing or Daily installation.

The standard is a polished, interruption-safe native transition faithful to the
user's sketch, not merely code that compiles. If an acceptance item is unproven,
state that precisely. Do not call the animation visually finished until actual
macOS recording and review support that claim.
