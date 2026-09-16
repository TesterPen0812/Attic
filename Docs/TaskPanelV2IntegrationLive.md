# Task Panel V2 — trusted Batch 4 integration live validation

## Trusted preview provenance

- Worktree: `/Users/taha/Developer/attic-task-panels-v2`
- Branch: `codex/attic-task-panels-v2`
- HEAD: `ae6418c1af690e29d15a20344cdb9765a23d3f85`
- Frozen dirty-status SHA-256: `77098eff892c8e7561ce7b25585c2053777e27d8ba31b97cf7c565feae67efe0`
- `.build/batch4.diff` SHA-256: `b0f0381941ea3b73ab6351459b698354372771760596a4f8e32647f106c61f66`
- Bundle: `com.taha.Attic.taskpanels.v2`
- Display name: `Attic Task Panels V2`
- Executable: `AtticTaskPanelsV2`
- Stub SHA-256: `eabf5cb33864e6d8aae15fc9d544726f23492f3d70becb147ba72c37b54bb7f5`
- Real code image `AtticTaskPanelsV2.debug.dylib` SHA-256:
  `5e68f56fb7a540faf8dd880e32ce089872a142dd58db05245b3cad82ac6d1c95`

The hardened launcher stopped only stale exact-path PID 69452. Its newly recorded PID 9983
passed the launcher's short health check but exited shortly afterwards, with empty stderr and no
crash report. The exact built app was then launched through the native CUA app surface as PID
10135. Before UI testing, PID 10135 was alive and the sole process whose command exactly matched
the preview executable path.

`lsof` showed PID 10135 mapping stub inode `139292913` and real-code inode `139292911`, sizes
41,008 and 20,452,688 bytes. Those exactly matched the current on-disk files. Evidence is in:

- `.build/integration-live/live-process.txt`
- `.build/integration-live/matching-pids.txt`
- `.build/integration-live/mapped-images.txt`
- `.build/integration-live/on-disk-images.txt`
- `.build/integration-live/image-hashes.txt`
- `.build/integration-live/launch.log`

All rendered observations below were made only after this mapping check. Local-only entitlements
were retained; no official Attic process or store was touched.

## Composer correction — pass

The prior Batch 3 P1 was a stale-process result. On trusted PID 10135 at the 332 pt panel width:

- the paperclip was visibly present with an empty title and accessibility exposed enabled
  `quick-entry-attach`, `Add attachment`;
- after entering `Batch 4 trusted composer fixture`, the paperclip remained present and enabled
  beside the enabled submit control;
- its picker selected the isolated 1.6 MB `batch3-image.png` fixture;
- the picker closed into a pending image card above the text row, inside the same shell;
- the shell visibly expanded upward while its lower edge and text row stayed anchored;
- accessibility exposed `quick-entry-attachments` and a pending image button described as
  `batch3-image.png, image, 1.6 MB`, with a `Remove` action;
- submitting created `Batch 4 trusted composer fixture` and cleared the composer; its new task row
  immediately showed passive `1 attachment` metadata;
- reopening the empty attachment picker and choosing Cancel returned cleanly to the unchanged,
  empty composer.

The dedicated created task and its private attachment remain in the isolated preview store; the
source fixture is unchanged.

### Pending-card removal follow-up — pass

On the same trusted PID, the draft `Pending removal preserves this draft` staged a new private
copy of the isolated 42-byte `batch3-normal-file.txt` fixture. The pending strip exposed that card
with its `Remove` action. Invoking `Remove` removed the pending strip and card, while the exact
draft title remained in the composer and no task was created. The original fixture's SHA-256 was
`e65cd7d7af0c85d02d2ed8dbe3747b5da8f24617e8a452ef8f7bb1ae36d647ee` both before and after.
The main panel was restored unpinned with the deliberate draft retained.

## R6 pointer travel and R7 gesture limits

No no-button pointer-move primitive or phase-owned trackpad gesture is available in the current
CUA surface. Clicks can open, pin and dismiss panels, but they change the exact hover/outside-click
conditions being tested. Synthetic cross-window drags in the previous focused pass also did not
deliver native drag sessions. Therefore this pass does not claim live proof for:

- ordinary pointer travel from a source row through the actual corridor to a displaced transient;
- crossing a pinned panel, hover replacement, latched hover/scroll-out retention, or the bounded
  outside-click gap;
- a physical two-finger follow-the-fingers dismissal, velocity completion, cancellation, vertical
  scroll rejection, pinned rejection or Reduce Motion presentation;
- keyboard-focus clipped-title disclosure.

These remain physical/manual integration gates. They were not inferred from source, builds,
harnesses or accessibility state.

## Actionable integration issue

The hardened launcher still reported success for PID 9983 even though that process exited shortly
after its 1.5 second health window. It did correctly remove the stale exact-path process and did
not match unrelated apps, but a successful launch record is not by itself durable live-process
proof. The independent sole-PID and mapped-inode checks above remain necessary until the preview
lifetime issue is resolved.

## Final Batch 4 fixes launcher refresh — pass

The fixed launcher was then exercised end to end on the frozen Batch 4 fixes source. It rebuilt
the same isolated preview and launched PID `23135` through LaunchServices. The launcher returned
success only after recording the launchd-owned process and both mapped images.

The new read-only `--verify` mode passed immediately and again five seconds later with identical
provenance:

- sole exact-path PID: `23135`
- parent PID: `1`
- recorded PID: `23135`
- stub: inode `139311655`, 41,008 bytes, SHA-256
  `0bc7adc63b9709ea811ab53b52815653e054077ebb0a0302e030eb789b986283`
- real code `AtticTaskPanelsV2.debug.dylib`: inode `139311653`, 20,485,968 bytes, SHA-256
  `4c41aee509b72d3da6fa883578bbef882e4b19775e1c74156782c2eba6eb0edf`

The mapped inode and size for each image exactly matched the current on-disk file in both checks.
Evidence is in `.build/integration-live/final-launch.log`,
`.build/integration-live/final-launch-provenance.txt`,
`.build/integration-live/final-verify-immediate.txt` and
`.build/integration-live/final-verify-delayed.txt`. This closes the launcher lifetime issue above
for the fixed path.

The final smoke confirmed the composer and `quick-entry-attach` remained visible, all retained
tasks and attachment counts were present, and the same retained task family opened, closed and
reopened successfully. The title-only draft `Pending removal preserves this draft` from the prior
process did not survive the required rebuild/relaunch; no pending attachment existed at restart.
R5 specifies preserving draft/items on submit failure, but does not explicitly require normal
process-relaunch persistence, so this observation is not classified as a Batch 4 regression.

The temporary `panel smoke only` title used to leave quick-entry focus was cleared. The family was
closed and the main panel restored unpinned. R6/R7 physical gates remain exactly as listed above;
no unsupported synthetic gesture or XCTest rerun was attempted.

No production or test source was edited, no XCTest retry was made, and no store was reset. The
main panel was restored unpinned. The exclusive UI lock was released after the pass.

## Final resource-fix preview refresh — pass with manual gates

The final frozen source (`ae6418c1af690e29d15a20344cdb9765a23d3f85`, final-fixes diff
`95baac6420344aed7bfa4d42595983079d07b1c092d`) was rebuilt and relaunched through the corrected
launcher. Its post-return `--verify` check passed with the sole exact-path process PID `38614`,
parent PID `1`, and recorded PID `38614`. The mapped images matched the rebuilt files:

- stub: inode `139334349`, 41,008 bytes, SHA-256
  `aa400886d4f32c7457750be38b51a418a18c8e960f7c922ee722d641cac69eb9`;
- real code `AtticTaskPanelsV2.debug.dylib`: inode `139334347`, 20,491,072 bytes, SHA-256
  `dba63f073107c75d720dfe52ac999d4e724bd047007282038a37e3939def679b`.

On that trusted preview, the main panel pinned and unpinned, the retained `Batch 4 trusted composer
fixture` family opened, closed with Escape, and reopened. In its Attachments view, the native picker
selected the isolated 42-byte `batch3-normal-file.txt` fixture and returned through the import
callback. The panel immediately rendered the new file card and the main row count changed from one
to two attachments. The source fixture was not modified. The family was closed and the main panel
was restored unpinned.

A 15-second read-only sample while the family was open in a clicked/latched state measured 15
samples at 0.493% average and 0.7% maximum CPU. This is an idle sanity pass only. CUA cannot move
the pointer without a button, so it could not establish a true hover-origin protected editing state
or count suspended close callbacks. F2's event-driven protected-hover behavior therefore remains a
manual/instrumented gate. The successful picker callback also does not independently prove F1's
weak-capture lifetime behavior; a lifecycle instrument or native drop/deallocation check remains
needed for that claim. R6/R7 physical gestures and keyboard-focus disclosure remain the previously
recorded manual gates. No unavailable drag or broad test suite was retried.

Evidence: `.build/integration-live/final-resource-launch.log`,
`.build/integration-live/final-resource-verify.txt`, and
`.build/integration-live/final-resource-cpu-sample.txt`.
