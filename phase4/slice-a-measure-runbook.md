# Canvas slice A: later Pro 120 Hz measurement

Owner amendment, 2026-10-27: use this Pro only; the Air is unavailable. This session also supplies the planned final Pro test. Part 1 built and tested the lab without opening it. **The 20% question remains unanswered.** No schema or renderer choice is qualified by compilation or the in-process stall test.

Allow **25–35 minutes after the build**, with **17 min 18 sec of capture**, 13 min 30 sec of synthetic input, and 76 fresh lab instances. Budget **40–50 minutes including a cold build and preflight**. These are schedule-derived estimates, not measured session durations. Stop for an ownership/permission/display failure; do not operate another app to make a guard pass. A failed run may need another session. Keep at least **80 GiB free** for raw recordings and luma; never remove owner data or empty the Trash to obtain space.

## Before the owner leaves

The later operator must already have Accessibility/event-posting and Screen Recording permission for these ad-hoc executables; helpers refuse without permission and do not prompt. Arrange a clear 320×520 pt space near the built-in display's upper-right visible area. Use the **Pro's built-in display at 120 Hz**, fixed Light appearance, constant power/background load. The recorder refuses external displays and advertised maxima other than 120 Hz. It records display ID, backing scale and current mode refresh rate; a zero mode rate means macOS did not expose a fixed physical rate. Do not change display settings during a run.

The session owns `/tmp/attic-screen.lock` using a nonblocking POSIX record lock, compatible with `/usr/bin/lockf`. If held, stop and wait. Never remove someone else's lock. The driver verifies the exact PID, bundle, executable, one compact window, frontmost ownership, no overlapping window above it, unchanged geometry and in-window coordinates before **every** post. It never activates other apps or posts modifier key-downs. Only the lab is quit, using `NSRunningApplication.terminate()` after checking its exact bundle ID, PID and executable; no Apple Events/Automation permission is used. No SSH, Air, owner-run folder, production identity, store, CloudKit or app data is involved.

## Exact commands

Run from this checkout, on `phase-3/restart`, after checking the worktree contains the reviewed commit. Do not run these screen commands as part of part 1.

```sh
cd /Users/taha/Projects/attic/attic-px-p3r
git status --short --branch
git log -1 --oneline
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
bundle exec ruby Scripts/generate_project.rb
bundle exec ruby Scripts/verify_project_generation.rb
Scripts/xcodebuild_locked.sh build -project Attic.xcodeproj -scheme CanvasLab \
  -configuration Local -destination 'platform=macOS' -derivedDataPath .build/dd-canvas-lab \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=
.build/dd-canvas-lab/Build/Products/Local/CanvasLabTests
python3 -m venv .build/canvas-analysis
.build/canvas-analysis/bin/python -m pip install -r CanvasLab/Analysis/requirements.txt
PYTHONDONTWRITEBYTECODE=1 .build/canvas-analysis/bin/python -m unittest discover \
  -s CanvasLab/Analysis -p 'test_*.py' -v
.build/canvas-analysis/bin/python CanvasLab/Analysis/run.py --plan
```

Only when the owner is away and this screen session is authorized:

```sh
CANVAS_RESULTS="/Users/taha/Projects/attic/attic-redesign-assets/phase4/slice-a-results/pro-120-$(date -u +%Y%m%dT%H%M%SZ)"
.build/canvas-analysis/bin/python CanvasLab/Analysis/run.py \
  --allow-screen --output "$CANVAS_RESULTS"
.build/canvas-analysis/bin/python CanvasLab/Analysis/report.py "$CANVAS_RESULTS"
```

The runner invokes only these built products: `CanvasLab.app/Contents/MacOS/CanvasLab`, `CanvasLabDriver` and `CanvasLabRecorder`, under `.build/dd-canvas-lab/Build/Products/Local/`. The app bundle ID is `com.taha.Attic.lab.canvas-canvaslab`. It records branch, exact SHA, executable path/hash and identity in `session.json`; per-cell `settings.json` and `capture-settings.json` record geometry and display provenance. The runner launches fresh instances, waits for app and recorder readiness, captures a baseline before input, records cost deltas, and quits its app in a `finally` block. An interruption retains evidence. If a guard refuses, inspect the cell log and leave other windows untouched; never bypass the guard.

## Sequence and frozen ceilings

1. Three fresh 10-second glass-free reference runs occur **before any candidate**. `frozen-ceilings.json` is created exclusively (never overwritten). For every metric and median/p95/p99/max: **ceiling = highest reference-run value + (highest − lowest)**. Reference hashes are stored. The predeclared instability rule is spread greater than `max(1 ms, 20% of the reference median)` for median/p95 of event→handler, event→submit and event→pixels. An unstable floor stops evaluation as inconclusive.
2. For each candidate glass condition **off, native glass 100%, native glass 35%**, repeat **R → C1 → R → C2 → R → C3 → R** three times. Every entry is a fresh 10-second instance; references share the same dimensions, location, driver, Light appearance and capture settings, and remain glass-free by definition. Later bracketing references check drift against the frozen ceiling; they never change it. Any drifting bracket makes the session inconclusive.
3. Four fresh 30-second strokes: reference, C1, C2, C3, glass off. These are long-stroke controls, not calibration inputs.
4. Six transition controls: reference/C1/C2, each asynchronous and deliberate synchronous reproducer. Each posts pan or Command-scroll zoom, then a one-second stroke at offsets **0, 2, 8 and 20 ms**, including while the dense raster worker is busy. These controls report each down's post→handler/event→handler, main/worker spans, cancellation/stale counts, pending depth and sampled peak RSS. They intentionally **do not claim pixel latency**: moving the viewport invalidates a single initial pixel baseline. Inspect `workers.csv` against `driver.csv` and `events.csv`; require no main-thread committed-raster spans in async mode, preserved posted/delivered counts, and transition latency within matched reference/idle spread. The sync C1/C2 controls must expose the regression; otherwise the transition test is inconclusive. Their expected failures must not be erased or pooled into normal ink metrics.

Input coalescing is off within the lab process and restored on normal quit; display link and board edge are off. Reference draws only new straight segments into a native bitmap from a layer-backed AppKit view's draw callback, with no glass, stored models or smoothing. Candidates use the deterministic 2,000×400 fixture. C1 retains a bitmap prefix plus ≤32-point shape tail; C2 uses a dedicated GPU queue and command-buffer presentation without waiting in input handlers; C3 adds bounded prediction to C1 and never commits predicted points.

## Capture, analysis and conclusions

Capture uses a ScreenCaptureKit **display stream including only the owned lab window, cropped to that window**, at its actual backing scale, requested 120 fps, no cursor/audio. It records complete-frame `displayTime` converted with the live mach timebase, plus callback time and encoder success. CGEvent timestamps are **nanoseconds**; app/driver/SCK timestamps are converted to the same uptime seconds. Never substitute callback or CA completion time for visible pixels. AppKit draw, CA flush and Metal present-enqueue are explicitly different submit markers; compare event→pixels for the owner's claim.

The analyzer finds exposed endpoints on a white pre-input baseline, excludes chrome and the earlier ink footprint, and finds the first frame with a dark center plus ≥3 dark pixels in its 3×3 patch. This handles 2 pt butt-capped ink without waiting for a later segment to fill all nine pixels. No witness means missing/occluded evidence, never an invented time. Coverage, eligible-but-unseen endpoints, posted/delivered/accepted counts, complete frames, actual distinct-complete fps and capture interval median/p95/p99/max accompany distributions. Verify an approximately **8.33 ms timestamp grid**; a request or advertised maximum is insufficient. Missing encoder/sidecar samples, lost delivered samples and noncausal timestamps invalidate the run.

**Every number must carry this limit:** ScreenCaptureKit samples WindowServer frames, not photons; only exposed witnesses are observed; capture overhead/scanout are uncalibrated; gaps are not automatically physical hitches. Never subtract an assumed capture delay. If fixed physical 120 Hz is unverified, qualify only the observed compositor capture, not physical ProMotion.

`measurement-report.json` keeps all three repeat distributions separate and reports counts, cadence, costs and frozen comparisons. A nonpredictive path earns the 20% statement only when **both median and p95 event→pixels are ≤80% of the frozen reference repeat medians in all three repeats**, evidence is valid, brackets are stable, and the other latency/tail metrics remain within their ceilings. Say plainly when neither C1 nor C2 reaches it. App/WindowServer CPU uses sampled cumulative CPU deltas; RSS is sampled, not an allocation peak; device GPU utilization is a proxy, not per-app GPU time/uploads. A missing GPU counter stays unmeasured.

C3 is reported separately: “appears X ms earlier than matched C1, with Y px typical sharp-turn overshoot,” using per-repeat captured endpoint medians and ≥45° turns in `prediction.csv`. Also report next-actual prediction error; signed early witnesses are permitted only for C3. Do not pool it into nonpredictive results or the 20% answer. Finish with an explicit renderer recommendation only after reviewing the evidence. Physical mouse/trackpad/tablet, inactive-first-click preservation, genuine glass appearance at both opacities and interrupted-session cleanup still need manual UAT in this later session; synthetic headless tests do not prove them.

Inspect a bounded sample of witness frames against retained raw luma/movie before accepting a result, especially C2 orientation, chrome, sharp turns and endpoint matching. Retained 2026-10-04 evidence has no luma/movie; part 1 revalidated its extracted joins and distributions, not its original pixels. Keep CSV/JSON/log evidence in this assets folder. After successful extraction and audit, move this session's full movies/luma and `.build/dd-canvas-lab` to the Trash (never permanently delete; never touch any `owner-run`). Do not rerun to discard a bad tail or inflate a ceiling. Preserve failure evidence and explain any replacement run.
