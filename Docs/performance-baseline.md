# Attic performance harness and Baseline A

This is the Phase 0 measurement contract for the local-only macOS app. The
machine-readable Baseline A is [performance-baseline-A.json](performance-baseline-A.json).
The first Baseline A in commit `9e0f99a` is superseded: its Tasks and Canvas
windows could auto-hide. No memory or CPU number here is a pass/fail target.
The gate remains a clear regression against a comparable baseline plus a
profile free of avoidable work.

## Fixture and safe launch

The SplitMix64 fixture has deterministic identifiers and 500 tasks with mixed
state/priority, subtasks, and 22 materialized PNGs; 200 varied-length notes,
12 with attachments; and 20 canvases with 2,000 objects each (1,700 strokes,
100 text objects, 100 shapes, and 100 images). Image payloads reuse one small
gradient PNG, so this does not simulate a collection of large photographs.
The seeder verifies persisted row counts before declaring the fixture ready.

The probe builds an ad-hoc signed `ATTIC_LOCAL_ONLY` preview with a fresh
`com.taha.Attic.perf.<random>` identity. It checks for CloudKit and APNs
entitlements, creates a disposable owned store inside that preview's sandbox,
and removes the owned store after the run. It also attempts to remove the
uniquely named container. macOS protects container-manager metadata and can
retain preferences, so a system-managed shell can remain; the script reports
that residue. The normal `com.taha.Attic` store is never opened. The UI metric
lane uses the separate `com.taha.Attic.perf.ui` identity and app-owned UUID
store roots; its cleanup launch uses an in-memory store.

```zsh
python3 Scripts/performance_probe.py --runs 3 --window 10 --output Docs/performance-baseline-A.json
```

`--done-history` adds 5,000 finished `TaskItem` rows completed on past days,
with `doneLoggedAt` set to the seed's cleanup time. They remain stored in the
Done log and do not appear in Now. This is seed version 2. Without the option,
the original 500-task fixture and seed version 1 remain unchanged, so Baseline A
can be reproduced and compared with another no-history run. Record B with:

```zsh
python3 Scripts/performance_probe.py --runs 3 --window 10 --done-history --output Docs/performance-baseline-B.json
```

Do not compare A and B as if they were the same workload.

## How the process probe measures

One run observes `hidden_idle`, `tasks_open`, `canvas_open`, `after_hide`, then
`hidden_idle_final`. The first idle window starts after 30 seconds hidden since
launch; `after_hide` starts after 30 seconds hidden since AppKit confirms the
hide; the final idle window follows after two seconds. Open phases also wait
two seconds. The panel is held visible during Tasks and Canvas, and the Canvas
selection must expose 1,700 seeded strokes. Tasks-to-Canvas page timing begins
while the panel is already visible. The app writes a separate end marker with
visibility, hover-monitor state, and transition count; the probe fails if any
changed during the window. The scripted hide returns the hover state machine
to its real hidden cadence. Its end-window timer starts only after AppKit
confirms the hide. The post-hide sample is followed by a second hidden window.
For the process probe, a `SIGUSR1` sent after each sampled window triggers its
end marker and the next phase. This event-driven handoff avoids overlap when a
large Canvas reveal or AppKit hide takes longer than expected. XCTest uses a
separate timed UI-test path because XCTest owns its measurements.
New phase markers also record the pointer's global AppKit coordinates. The
recorded Baseline A predates that metadata; its sampling method is unchanged.
For future local baselines, park the pointer away from the configured corner
and keep it still throughout the locked run.

Each window records two `footprint -j` physical footprint readings, process
CPU time, and process interrupt wake-ups. Rates use the actual elapsed window
length. The raw package idle wake-up counter remains in JSON for inspection,
but it returned zero throughout the earlier Apple Silicon runs and is not a
gate or a summary measure. The probe holds `/tmp/attic-xcodebuild.lock` from
seeding through the end of all measured runs. Its preview build uses
`xcodebuild-locked.sh` on this Mac. Xcode build products and raw footprint
reports remain under `.build/performance/`; probe-owned store data is removed
after each invocation. A protected container shell may remain as noted above.

## XCTest and signposts

```zsh
export PATH=/opt/homebrew/opt/ruby/bin:$PATH
bundle exec ruby Scripts/generate_project.rb && bundle exec ruby Scripts/verify_project_generation.rb
F=(CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
/Users/taha/Developer/attic-redesign-assets/xcodebuild-locked.sh build-for-testing -project Attic.xcodeproj -scheme Attic -configuration Local -destination 'platform=macOS' -derivedDataPath .build/dd "${F[@]}"
/Users/taha/Developer/attic-redesign-assets/xcodebuild-locked.sh test-without-building -project Attic.xcodeproj -scheme Attic -configuration Local -destination 'platform=macOS' -derivedDataPath .build/dd "${F[@]}"
F+=(ATTIC_MACOS_BUNDLE_IDENTIFIER=com.taha.Attic.perf.ui)
/Users/taha/Developer/attic-redesign-assets/xcodebuild-locked.sh build-for-testing -project Attic.xcodeproj -scheme AtticUI -configuration Local -destination 'platform=macOS' -derivedDataPath .build/dd-ui "${F[@]}"
/Users/taha/Developer/attic-redesign-assets/xcodebuild-locked.sh test-without-building -project Attic.xcodeproj -scheme AtticUI -configuration Local -destination 'platform=macOS' -derivedDataPath .build/dd-ui -only-testing:AtticUITests/PerformanceUITests "${F[@]}"
```

The five performance UI tests record `XCTApplicationLaunchMetric`,
`XCTMemoryMetric`, and `XCTCPUMetric` on seeded states. These are recorded
metrics, with no accepted XCTest baseline and no CI threshold. The CPU metric
around a two-second sleep can read near zero; the process probe is the CPU
and wake-up comparison. The existing Task and Canvas unit performance gates
remain in the full unit suite. The after-hide UI metric waits 30 seconds after
the panel disappears, matching the process probe's settled after-hide state;
the Tasks and Canvas tests assert their selected section after measurement.

All `OSSignposter` intervals use subsystem `com.taha.Attic`, category
`Performance`. The small timing file is written only for a validated external
probe root. Names describe the actual endpoint:

| Interval | Boundaries |
| --- | --- |
| `CoordinatorInitToMenuStarted` | `AppCoordinator.init` to completion of `AppDelegate` shell start; not process launch or first frame. |
| `PanelRevealToOrderedFront` | corner/programmatic decision to AppKit order-front, before animation and screen scan-out. |
| `PageSwitch` | section selection to the next main turn after SwiftUI observes it, not a pixel-visible frame. |
| `StoreOpen`, `StoreSave` | SwiftData container construction and task/note/canvas context save. |
| `NoteKeystrokeToDraw`, `CanvasDragToDraw` | native input event to view draw callback. |

The automated harness records the first three intervals and `StoreOpen`.
It does not drive note typing, canvas drawing, or a store save, so those three
intervals require a separate interactive Instruments trace. None of these
signposts proves scan-out latency. The spec's only fixed perception budgets
remain reveal ≤100 ms, page switch ≤50 ms, and note keystroke to screen ≤16 ms;
use a frame trace to judge those endpoints.

## CI comparison

The performance comparison runs in its own `macos-26` job on a fresh runner,
apart from the build, unit, UI, and analyzer job. It builds the pinned
reference and candidate there, then alternates six runs per side in balanced
AB/BA order. A primary series separates only if **every** candidate run is
above **every** reference run. Primary series are settled hidden footprint,
hidden CPU, hidden interrupt wake-ups, after-hide footprint, final hidden
footprint, and the **first** reveal-to-order-front timing in each run. Every
other phase and timing is printed for review; package idle wake-ups are
excluded. A suspected regression triggers six fresh pairs. Only a primary
measure that separates again in the confirmation is reported with a GitHub
`::warning::` annotation. This is a same-run ordering comparison, not a
universal memory or CPU target.

The performance UI lane uses the same ad-hoc signed sandbox configuration as
local verification. Both new performance lanes remain **non-blocking** until
they pass at least once on `macos-26` with Xcode 26.6; signed UI automation,
`open --env`, and `footprint` have not been verified on that runner. Their
outcomes and artifacts are reported without skipping the analyzer or final
worktree checks. The comparison job records actual sampling and confirmation
durations in its artifact. Those CI durations are pending the first run;
later promotion to a blocking gate should use observed durations and variance.

The `PERF_REFERENCE_COMMIT` SHA in the workflow must remain reachable after
merge: merge commits, not squash. Advance it deliberately with a new baseline
and compatible fixture/schema when the implementation or data model changes.

For a local same-machine comparison with at least six comparable runs per side:

```zsh
python3 Scripts/compare_performance.py path/to/reference.json path/to/candidate.json
```

## Baseline A results

Recorded 2026-09-24 19:56:47 UTC on an Apple M4, macOS 27.0, Xcode 27.0,
branch `redesign/p0-perf`, commit `66298945ac71e86f3bfa9b5f3976f1f41e25bd8b`.
The ad-hoc local-only executable was
`.build/performance/dd/Build/Products/Local/AtticPerf9fd44b290a.app/Contents/MacOS/AtticPerf9fd44b290a`
with bundle ID `com.taha.Attic.perf.9fd44b290a`. Three fresh stores used seed
version 1 with 500 tasks, 200 notes, and 20 × 2,000 canvas objects; no extra
Done tasks. Each sampled window lasted approximately 10.1 seconds. The build
lock covered all seeding and samples. This is a local development Mac baseline,
not a `macos-26` runner baseline.

Each cell shows the three run values followed by the run-to-run spread
(maximum minus minimum). Physical footprint is the end reading in MiB; CPU is
percent of one core, and wake-ups are process interrupt wake-ups per second.

| Phase | Footprint MiB, runs 1/2/3; spread | CPU %, runs 1/2/3; spread | Wake-ups/s, runs 1/2/3; spread |
| --- | ---: | ---: | ---: |
| Hidden idle, settled | 160.27 / 163.33 / 159.99; 3.34 | 0.02 / 0.83 / 2.95; 2.93 | 0.99 / 20.10 / 62.17; 61.18 |
| Tasks open | 170.53 / 235.14 / 164.42; 70.72 | 0.02 / 2.38 / 2.18; 2.36 | 0.79 / 15.50 / 41.60; 40.81 |
| Large canvas open | 113.92 / 113.52 / 123.92; 10.41 | 4.11 / 0.27 / 1.06; 3.84 | 27.65 / 5.23 / 10.36; 22.42 |
| After hide, settled | 112.91 / 113.63 / 122.97; 10.06 | 0.03 / 0.65 / 1.57; 1.54 | 1.09 / 17.32 / 27.64; 26.55 |
| Final hidden idle | 112.92 / 113.63 / 122.97; 10.05 | 1.53 / 0.99 / 2.37; 1.38 | 33.97 / 24.38 / 51.93; 27.55 |

All 15 end markers agreed with their start visibility and hover state: Tasks
and Canvas remained visible, and all hidden windows remained hidden. Each
Canvas marker confirmed 1,700 seeded strokes. The Tasks footprint rose to
235.14 MiB in run 2 and fell by the Canvas window; this is observed
within-run movement, not a new budget.

| Event | Run values, ms | Run-to-run spread, ms |
| --- | ---: | ---: |
| Coordinator init to menu shell started | 955.72 / 1117.09 / 1208.84 | 253.12 |
| Store open | 10.01 / 12.57 / 8.69 | 3.88 |
| First reveal to order-front | 261.75 / 225.33 / 230.61 | 36.43 |
| Later in-panel order-front | 1.20 / 4.43 / 16.96 | 15.76 |
| Tasks-to-Canvas page switch proxy | 312.33 / 352.86 / 540.11 | 227.78 |

The first reveal and page-switch proxies exceed the spec's perception budgets
in these runs. Their signpost endpoints are order-front and a SwiftUI layout
turn, so a frame trace is needed to determine pixel-visible latency. This is a
profiling lead for a later optimization phase, not a harness failure.

The ranges show run-to-run spread across fresh seeded stores. The JSON retains
all individual samples and start/end footprint values. CPU and interrupt
wake-ups can vary with unrelated Mac activity despite the build lock; a single
run is not a regression verdict.

## Limits and observed waste

- The corner monitor still polls on a one-second hidden cadence, with a
  250 ms leeway, and switches to 50 ms near the corner. This conflicts with
  the redesign's no-polling-while-hidden goal. Phase 0 reports it for later
  optimization and profiling.
- Hidden interrupt wake-ups ranged from 0.99 to 62.17 per second in the first
  settled window and 24.38 to 51.93 per second in the final hidden window.
  The first run measured 0.02% hidden CPU and about one wake-up per second,
  while other runs reached 2.95% and 62.17 wake-ups per second. Pointer motion
  may contribute: mouse events can sample the corner monitor at 30 Hz. The
  old baseline has no pointer coordinates, so attribution needs a parked,
  still-pointer trace as well as profiling of other hidden work.
- Footprint started at 160–163 MiB hidden. In runs 1–2 the first visible
  Tasks-to-Canvas sequence ended at 113–114 MiB and stayed there, roughly
  47–50 MiB below launch idle; run 3 settled at 123 MiB. This retained launch
  footprint is observed waste to profile, with its owner still unknown.
  Canvas was not settled either: run 2 fell from 172.36 to 113.52 MiB during
  the Canvas window.
  End readings alone do not describe its peak or steady state.
- The signpost endpoints precede physical display scan-out. Ink latency and
  note keystroke-to-screen remain unmeasured until an interactive frame trace.
  `StoreSave` also has no automated driving workload yet.
- Same-run CI comparison controls runner type, fixture, and order, but memory
  pressure and background load can still move footprint and wake-ups. The
  non-blocking CI period is needed to learn that variance.
- For later phases, retain the same-run comparison JSON and an Instruments
  trace of hidden idle, Tasks, large Canvas, and hide. Inspect Points of
  Interest, Time Profiler, SwiftUI, and Core Animation for offscreen work or a
  blocked main thread. A numeric pass alone cannot satisfy the separate
  no-waste-in-profiling gate; the hidden corner timer is already a finding.
