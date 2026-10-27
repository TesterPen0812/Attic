# Canvas measurement lab

A separate `CanvasLab` scheme builds the store-free lab app, guarded input driver,
window-filtered ScreenCaptureKit recorder and a **command-line, windowless** unit
test executable. No target is linked into Attic, its invisible host or iPhone.
The shipping Canvas and models are untouched.

The later on-screen commands, schedule, frozen reference rule, limits and cleanup
are in [`../phase4/slice-a-measure-runbook.md`](../phase4/slice-a-measure-runbook.md).
Do not launch the app, driver or recorder during part 1. Each has a separate
explicit screen/event/capture opt-in flag. The test executable constructs an
unposted CGEvent to check clock conversion; it never posts input or opens a window.

Core invariants: immutable fixture/linked geometry handles; one serial raster
worker and one latest pending request; bounded cancellation batches; generation
checks before delivery and full revision/viewport/scale/appearance key checks
before installation. C1 retains live ink until an installed raster includes its
revision. C2 rechecks its key on the GPU queue, never acquires a drawable in input,
and replays active ink with one GPU submission. Synchronous mode is an explicit
negative control using the same viewport raster, never a production alternative.

`Analysis/analyze.py` ports the retained `analyze-video.py` and
`audit-witnesses.py`; `Recorder/main.swift` ports `record-display-spike.swift`.
`Analysis/scan-kdebug.py` removes the original fixed paths and rejects partial XML;
its global timestamps remain insufficient to identify ink presentation.
The lost spike runner, PID/geometry assumptions and driver were replaced rather
than copied from scripts with unavailable imports. The old independent-window
recorder is intentionally superseded by display-including-only-window capture.
`run.py` replaces old pilot/matrix/repeat runners; `report.py` replaces
summarize/finalize/report glue without reconstructing the 384-cell matrix.

Retained validation is headless and reads only CSV/JSON:

```sh
python3 CanvasLab/Analysis/analyze.py retained \
  /Users/taha/Projects/attic/attic-redesign-assets/phase4/spike-results/overnight-20261004 \
  /tmp/canvas-retained-check.json
```

This reconstructs **19 extracted cells and 10,223 witnesses**, checks endpoint
exposure, joins frame timestamps, and reproduces median/p95/p99/max to 1e-7 ms.
It does not make the historical failed/unqualified spike pass. Original movies
and luma are absent; their extraction cannot be rerun from the retained folder.
New extraction uses explicit capture geometry and a dark-center/three-pixel
patch criterion instead of the old all-nine-pixels rule. Synthetic slow-stroke
pixels test the repaired oracle, including an injected 100 ms presentation delay.
The other negative controls test handler delay, dropped accepted/capture samples,
negative timestamps, immutable ceilings, unstable references and C3 exclusion.

All Xcode builds use `Scripts/xcodebuild_locked.sh`, ad-hoc signing and the lab
bundle family `com.taha.Attic.lab.canvas-*`. Only `CanvasLabTests` is executed
headlessly. CI's `canvas-lab` job builds all four products and runs the same tests.
