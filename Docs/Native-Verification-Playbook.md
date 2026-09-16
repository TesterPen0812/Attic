# Attic native verification playbook

Purpose: every native or visual verification pass starts from this file instead
of re-discovering how to drive the app. The lessons accumulate here; the agent
that runs a pass is always a fresh session pointed at this playbook. A
long-lived verifier thread is deliberately not used: a thread that already
passed an earlier batch tends to report from memory of the previous build
instead of from the build in front of it.

## 1. Build and launch an isolated preview

    Scripts/launch_local_preview.zsh \
      --display-name 'Attic <purpose> <date>' \
      --bundle-id com.taha.Attic.<purpose>.<date> \
      --executable-name Attic<Purpose><Date> \
      --derived-data /tmp/attic-<purpose>-dd \
      --appearance dark

Flags that matter: `--verify` checks that exactly one launchd-owned process runs
this preview and that it maps the on-disk executable and debug dylib, then
prints that provenance without launching anything. `--build-only` builds and
emits provenance without launching. `--dry-run` prints the resolved settings
and build command.

Never launch or read the store of `com.taha.Attic`. Never touch
`/Applications`. Any leftover preview from an earlier run may be quit by its
exact bundle path so the screen is unambiguous; never kill unrelated processes.

## 2. Prove the running process before interacting

Record the PID, the executable path and the debug dylib path, and confirm the
process maps the artefacts you just built. Re-check after any relaunch. A build
that succeeded is not evidence that the thing on screen is that build.

## 3. Reaching the task subpanel

- Single-clicking a task row opens that task's subpanel.
- Right-clicking a task row also reveals it, and this is the more reliable route
  when automation cannot otherwise see the panel.
- If the task sub-panel does not open, open it manually using double-click,
  then "Add Task". This setup may be necessary before the panel becomes
  available for inspection.
- The subpanel has two views, Subtasks and Attachments, switched from a control
  beside the bottom composer. It must not dismiss on a two-finger swipe; that
  gesture was deliberately removed.

## 4. What the computer-use surface cannot drive

Mark these UNVERIFIED rather than guessing, and never restate them as passes:

- Physical trackpad pinch. A Zoom menu result is not pinch evidence.
- Holding a pointer interaction open to inject a phased scroll or magnification
  sequence, cancel it, and then deliver that same sequence's tail.
- Destructive actions behind an action-time confirmation, such as deleting a
  board. Reaching the confirmation and cancelling is BLOCKED, not a pass.
- Persistence-failure behaviour: there is no safe native seam for injecting a
  failed save. Source tests cover it; a native run must not claim it.

## 5. Evidence conventions

Report each scenario as PASS, FAIL, UNVERIFIED or BLOCKED, with what was
directly observed. Write screenshots to a per-run directory under `/tmp` and
reference them. Include the build identity, executable and debug dylib hashes,
the verified PID, and explicit lists of what passed, failed and remained
unverified. A tooling limitation is not a product defect, and a product defect
is not a tooling failure. Do not redesign or fix anything during a verification
pass.

## 6. Clean up

Quit the preview when the pass ends and say which processes were left running.
No commits, no pushes, no release or install work.
