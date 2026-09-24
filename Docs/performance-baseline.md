# Attic performance harness and Baseline A

Recorded 2026-09-24 on the local-only macOS app. The machine-readable samples
are in [performance-baseline-A.json](performance-baseline-A.json). Baseline B is
reserved for the data-foundation merge and its 5,000 extra Done tasks.

## Reproduce

Run from the repository root. The probe builds an ad-hoc signed preview with a
unique `com.taha.Attic.perf.*` bundle identifier and a local-only entitlement
set. It first launches the preview with an in-memory test store to let macOS
create the sandbox, then seeds a fresh owned directory below that preview's
`AtticPerformanceStores` directory. The owner token, bundle identity, and
`ATTIC_UI_TESTING`/`ATTIC_UI_TEST_CANVAS_PERSISTENCE` flags are all required by
the app. The probe deletes only the directory it created; it never opens the
official Attic store. Its build uses `xcodebuild-locked.sh` on this Mac; the
entire measurement phase holds `/tmp/attic-xcodebuild.lock`.

```zsh
python3 Scripts/performance_probe.py --runs 3 --window 10 --output Docs/performance-baseline-A.json
python3 Scripts/performance_probe.py --runs 3 --window 10 --done-history --output Docs/performance-baseline-B.json
```

The second command is the one-command Baseline B rerun **after** data
foundation lands. The flag adds 5,000 done `TaskItem` rows whose `completedAt`
is today, so daily cleanup cannot remove them during the run. Baseline A omits
those extra rows. The ordinary 500-task mix includes some done tasks in both
fixtures. Do not compare A and B as if they had the same workload.

The flag was smoke-tested locally with one run and a two-second window; seeding
and all four phases completed. That one-run output is intentionally not a
recorded Baseline B.

The fixture uses a fixed SplitMix64 seed and deterministic UUIDs. It contains
500 tasks with varied status/priority, every fifth item a subtask, and 22
materialized 128-pixel PNG attachments; 200 varied-length notes, 12 with PNG
attachments; and 20 canvases with 2,000 objects each (1,700 strokes, 100
editable text objects, 100 shapes, and 100 images per board). Relative dates
are anchored to the run's local day so completed tasks remain in today's data.
The seeder checks stored row counts before marking the fixture ready. Image
payloads reuse one gradient PNG; this stresses object count and decoding paths
without pretending to represent a library of large photographs.

The four phase markers are `hidden_idle`, `tasks_open`, `canvas_open`, and
`after_hide`. The app's corner monitor runs during the probe, including its
existing hidden cadence. The canvas phase verifies 1,700 selected strokes.
The hide marker is emitted only after AppKit orders the panel out. Each phase
settles for two seconds, then records ten seconds of process CPU and kernel
package idle wake-up counter deltas, with `footprint -p PID` at both ends.
`footprint` is the physical footprint shown as Memory in Activity Monitor.
The JSON preserves raw samples and Apple's per-phase footprint JSON files
remain under `.build/performance/run-N/` until that build folder is removed.
On this Apple M4/macOS 27 run, the package idle wake-up counter returned zero
for every phase. The separate interrupt wake-up counter moved and is reported
as an additional rate; it is not relabeled as idle wake-ups.

## XCTest and signposts

```zsh
export PATH=/opt/homebrew/opt/ruby/bin:$PATH
bundle exec ruby Scripts/generate_project.rb
bundle exec ruby Scripts/verify_project_generation.rb
F=(CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
/Users/taha/Developer/attic-redesign-assets/xcodebuild-locked.sh build-for-testing -project Attic.xcodeproj -scheme Attic -configuration Local -destination 'platform=macOS' -derivedDataPath .build/dd "${F[@]}"
/Users/taha/Developer/attic-redesign-assets/xcodebuild-locked.sh test-without-building -project Attic.xcodeproj -scheme Attic -configuration Local -destination 'platform=macOS' -derivedDataPath .build/dd "${F[@]}"
/Users/taha/Developer/attic-redesign-assets/xcodebuild-locked.sh build-for-testing -project Attic.xcodeproj -scheme AtticUI -configuration Local -destination 'platform=macOS' -derivedDataPath .build/dd-ui "${F[@]}"
/Users/taha/Developer/attic-redesign-assets/xcodebuild-locked.sh test-without-building -project Attic.xcodeproj -scheme AtticUI -configuration Local -destination 'platform=macOS' -derivedDataPath .build/dd-ui -only-testing:AtticUITests/PerformanceUITests "${F[@]}"
```

Five UI test methods record `XCTApplicationLaunchMetric` on the seeded store
and `XCTMemoryMetric(application:)` plus `XCTCPUMetric(application:)` in all
four states. XCTest permits one metric set per method. The test also exercises
actual panel navigation on the seed. The UI runner cannot write the app's
sandbox, so each test gives the app a UUID; the app creates and removes its
own disposable `AtticPerformanceStores/attic-perf-ui-*` root under
`ATTIC_UI_TESTING`. The test app never opens the normal store. The
existing `TaskPerformanceGateTests` and `CanvasPerformanceGateTests` remain in
the full unit suite; no duplicate scaling benchmark was added.

All `OSSignposter` events use subsystem `com.taha.Attic`, category
`Performance`. A disabled signposter performs no signpost operation. The
probe's owned root also enables a small event-time recording file, read into
the run JSON. `AppLaunchToMenuReady` starts in `AppCoordinator.init` and ends
after `AppDelegate` starts the menu shell; it is an app-initialization proxy,
while `XCTApplicationLaunchMetric` measures first responsive frame.
`StoreOpen` wraps `ModelContainer` construction; `StoreSave` wraps task, note,
and canvas context saves. `PanelRevealToInteractive` starts at the corner or
programmatic reveal decision and ends after AppKit orders the panel front.
`PageSwitch` begins at section selection and ends on the next main turn after
SwiftUI observes the new section. `NoteKeystrokeToDraw` runs from the native
text view's key-down to its draw call; `CanvasDragToDraw` runs from a drawing
drag event to the canvas view's draw call. These are useful render-path
proxies, not proof of physical screen scan-out or a 120 fps trace. Use
Instruments Points of Interest plus Core Animation for the perceptual budgets.

The only fixed speed budgets are the spec's 100 ms reveal, 50 ms page switch,
and 16 ms note keystroke-to-screen. Neither XCTest automation-click duration
nor CI wall-clock timing is substituted for them. Ink latency still needs a
real ten-second scribble and frame trace on a ProMotion display.

## CI comparison

The `macos-26` job runs the seeded UI metrics and builds both the pinned Phase
0 reference and the candidate preview on **the same runner**. Each is probed
three times. `Scripts/compare_performance.py` rejects mismatched hardware, OS,
Xcode, fixture, and window length. It compares each phase's footprint, CPU,
idle and interrupt wake-ups, and each run's event timings (the slowest reveal
and median of other same-name events). It fails only if every candidate
observation is beyond the reference's maximum plus one additional
reference run-to-run spread. This detects a clear repeated regression without
claiming a universal memory or CPU budget. Ambiguous changes stay review
items; the JSON and XCTest result bundles are uploaded. The reference SHA must
be advanced deliberately, and both CI probe commands must add
`--done-history`, when Baseline B replaces A.

Local baseline comparison, with matching machine, OS, Xcode, fixture, and window:

```zsh
python3 Scripts/compare_performance.py Docs/performance-baseline-A.json path/to/new-run.json
```

## Baseline A results

Recorded 2026-09-24 17:30:13 UTC at app commit
`635fdf5ac2f50329e75ae83b098eeaf7dbf2cc59` on an Apple M4, macOS 27.0,
Xcode 27.0. The local-only preview was `com.taha.Attic.perf.250539c622`, at
`.build/performance/dd/Build/Products/Local/AtticPerf250539c622.app/Contents/MacOS/AtticPerf250539c622`.
Three fresh stores were seeded and probed for ten seconds per phase under the
machine-wide build lock. No extra 5,000 Done tasks were included.

| Phase | Physical footprint, MiB | CPU, one-core % | Package idle wake-ups/s | Interrupt wake-ups/s |
| --- | ---: | ---: | ---: | ---: |
| Hidden idle | 159.66–163.13 | 0.04–0.05 | 0.00–0.00 | 1.68–1.98 |
| Tasks open | 163.09–200.03 | 0.67–58.22 | 0.00–0.00 | 8.22–42.32 |
| 2,000-object canvas open | 91.24–116.95 | 0.01–26.89 | 0.00–0.00 | 0.59–110.63 |
| After hiding canvas | 91.70–105.03 | 0.02–2.21 | 0.00–0.00 | 0.99–46.40 |

Ranges are minimum to maximum of three runs. Footprint is the end of each
window; rates use counter deltas over the actual window duration. The Tasks
and Canvas CPU ranges are wide, so a single local observation is not a
credible regression verdict. The machine also had substantial unrelated
load during this session, despite the build lock; the JSON keeps all three
runs, including the high ones. Interrupt rates were derived afterward from
the original per-window counter and duration in the JSON; no app or window
was rerun for that extra column.

In-process event ranges: `AppLaunchToMenuReady` 706.50–884.23 ms (3),
`StoreOpen` 7.48–12.50 ms (3), `PanelRevealToInteractive` 0.42–78.84 ms
(8, including later warm reveals), and `PageSwitch` 277.23–352.36 ms (3).
The initial reveal in each run was 62.42–78.84 ms. These endpoints precede
physical scan-out; the canvas page-switch proxy is nevertheless far above the
spec's 50 ms perception budget and needs a real frame trace before any claim
of compliance. No note typing or drawing drag was generated by this probe.

For each later phase, save its same-run comparison JSON and an Instruments
trace of hidden idle, Tasks, the large canvas, and hide. Inspect Points of
Interest, Time Profiler, SwiftUI, and Core Animation for repeated offscreen
work or a blocked main thread. A passing numeric comparison alone does not
establish the separate “no waste found in profiling” condition. The hidden
corner timer below is already a finding to resolve and reprofile.

## Limits and waste observed

- Hosted runner measurements are comparable only within one runner job.
  Physical footprint can move under macOS memory pressure; CPU and package
  idle wake-up counters are deltas, not an Energy Impact score. The zero
  package idle wake-up series on this machine cannot establish zero wake-ups;
  the nonzero interrupt series is kept separately and compared in CI.
- The preview records no note keystrokes or pen drags by itself. Those
  signposts require an interactive trace, and the pixel-visible endpoints
  remain unmeasured until that trace is run.
- The final local `AtticUI` performance class passed all five tests. Earlier
  attempts exposed a runner automation timeout and a sandbox boundary; a
  further attempt exposed XCTest's one-metric-set-per-method rule. The final
  result bundle is under `.build/dd-ui/Logs/Test/`. These local Xcode 27
  results do not substitute for the Xcode 26.6 CI lane.
- The first full unit rerun after the UI seam change had five
  `PanelGeometryTests` gesture assertion failures. The focused class then
  passed 74 tests, and the repeated full suite passed 918 with four skipped.
  No cause was established for the one failing run; retain the logs under
  `.build/` and watch this class in CI.
- In two exploratory UI runs, a synthesized click on the Tasks dock button
  after visiting Canvas did not change selection. The existing Command-1
  shortcut did, and the final navigation test uses it. The click outcome may
  be an automation/hover issue or an app issue; it needs separate native UAT.
- `CornerHoverMonitor` currently runs a repeating hidden timer: its idle
  cadence is 1,000 ms, with a 250 ms leeway, and its near-corner cadence is
  50 ms. This conflicts with the redesign's no-polling-while-hidden goal.
  Phase 0 measures and reports it; optimization belongs to a later stream.
- One after-hide run had 2.21% of one core and 46.40 interrupt wake-ups/s,
  versus 0.02–0.04% and 0.99–1.09/s in the other two. The probe did not
  identify the cause. The separate one-run Done-flag smoke also reached 2.73%
  and 51.81/s after hide; inspect a trace before assigning cause.
