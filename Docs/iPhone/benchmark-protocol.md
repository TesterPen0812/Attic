# iPhone rendering benchmark: Stage 3 measurement protocol

**Status: source preparation only.** There are no measurements in this document. The lead runs the hosted tests on the Air after the Stage 2 gate is recorded. A complete benchmark contributes one piece of Stage 3 evidence; it does not validate the shell, seed data, all unit tests, or a physical iPhone.

## Run on the Air

Use the integrated checkout with `PhoneRenderingBenchmarks.swift` in the generated `AtticMobileTests` target and that target in the `AtticMobile` scheme. The generator collects Swift files under `AtticMobileTests`; the lead owns regeneration and verification. The project checked in on this preparation branch does not yet reference the benchmark file. Use the dedicated, portrait, headless **synthetic** iPhone Simulator on the Air, the same runtime/device and keyboard configuration throughout, and the job's existing DerivedData. The host must run in local-only test mode with only in-memory or synthetic data. Do not point this invocation at a personal simulator.

Run from the repository root on the Air with `UDID` set to the exact dedicated simulator UUID, `AIR_JOB` set to its job directory, and `RESULT_BUNDLE` set to a **new** `.xcresult` path for this run. Keep the bundle and console log together. Do not run unrelated jobs concurrently on the Simulator.

```sh
: "${UDID:?Set the synthetic iPhone Simulator UUID}" "${AIR_JOB:?Set the Air job directory}" "${RESULT_BUNDLE:?Set an unused .xcresult path}"
TEST_RUNNER_ATTIC_PHONE_BENCH_UDID="$UDID" Scripts/xcodebuild_locked.sh test \
  -project Attic.xcodeproj -scheme AtticMobile -configuration Local \
  -destination "platform=iOS Simulator,id=$UDID" -parallel-testing-enabled NO \
  -derivedDataPath "$AIR_JOB/DerivedData" -resultBundlePath "$RESULT_BUNDLE" \
  -only-testing:AtticMobileTests/PhoneRenderingBenchmarks CODE_SIGNING_ALLOWED=NO
```

`TEST_RUNNER_` forwards the opt-in to the hosted process as `ATTIC_PHONE_BENCH_UDID`; the test compares it with `SIMULATOR_UDID`. No opt-in skips the cases. A mismatched UUID, missing scheme test marker, wrong device idiom, or unavailable foreground host fails the opted-in run. Other platforms cannot exercise the fixtures. The UUID match prevents accidental selection; it cannot inspect or certify the simulator's provenance. To isolate a failing workload, append `/testTaskListScroll`, `/testTableNoteScroll`, or `/testTableNoteTyping` to the selector. A diagnostic subset is not a complete comparison.

## What is compared

Both engines receive the same deterministic content in a 320 × 320 pt light viewport. Each case runs four paired rounds; the order is UIKit/SwiftUI, SwiftUI/UIKit, UIKit/SwiftUI, SwiftUI/UIKit. Each trial creates a fresh fixture, clock and window in the current hosted scene. It exercises an unreported warm-up, measures idle cadence, then records the workload. When the trial exits it invalidates the display link and timer, ends fixture editing, hides and detaches the window and checks that the original host window regains key status. No application models, stores, accounts, input files, keyboard events on the Mac, or product screens are used by the fixture.

| XCTest | Surfaces and fixed input | Work the trial must witness |
| --- | --- | --- |
| `testTaskListScroll` | Reusable `UICollectionView` cells vs SwiftUI `ScrollView`/`LazyVStack`: the same ordered set of 2,000 synthetic task titles, 44 pt per row. From indices 0, 1000 and 1940, take 48 steps of 44 pt each (144 actions per trial). | Full scrollable height, observed offset at each step, presentation-layer bounds at that offset, and the matching real title visible at both ends of each segment. |
| `testTableNoteScroll` | UIKit scroll/stack views vs SwiftUI `ScrollView`/`VStack`. Each note has 48 paragraphs, each followed by a 4-row × 3-column table: 576 cells, 216 pt per section. From sections 0, 24 and 39, take 48 steps of 27 pt each (144 actions). | Full document height, model and presentation offsets at every step, and the matching first cell visible in both the starting and ending tables. |
| `testTableNoteTyping` | Same table-heavy note; the paragraph in section 24 is a UIKit TextKit 2 `UITextView` or SwiftUI bound `TextEditor`. Both receive the same sequence of 48 single-character edits through `insertText` / `deleteBackward`, starting at the end of that paragraph. Every eighth action deletes. | The input view is attached and focused. After every edit, its text, the delegate/binding value and the UTF-16 caret match the expected result; the caret is in the viewport and clear of the keyboard. The adjacent table cell is visible before and after. |

The list is virtualized in both engines; both note fixtures construct the tables eagerly. The 320 pt viewport leaves sufficient runway at the last anchor and keeps the active paragraph and its table above the keyboard in portrait. A few identical `UILabel` witnesses identify actual task titles and table cells in both engines. They are checked by text and geometry outside timed scroll segments. Jumps to anchors, keyboard presentation, warm-up edits (undone before sampling), idle calibration and checkpoint scans are excluded from the workload.

## Timing and interpretation

The `CADisplayLink` requests 60 Hz on the main run loop in common modes. After warm-up, each trial retains 24 observed idle timestamp intervals. A median more than 1.7 ms from 1000/60 ms fails calibration: the two engines must not be compared at materially different idle cadences. There is no pass/fail speed threshold. A clock phase that never observes the required state times out and fails instead of emitting placeholder samples.

The driver issues one operation in a callback and timestamps it with `CACurrentMediaTime()` immediately before mutation. Once the expected UI state is observable, it records `stateObservedAt`; the first subsequent display-link `timestamp` at or after that observation, with the expected state still present, is `refreshAt`. For scrolling, the layer's presentation bounds must also match the commanded offset within 1 pt. For typing, the editor's text, binding/delegate state, selection and visible caret must agree. Only then does the driver issue the next input. `targetTimestamp` is a forecast and is not used as evidence of display.

For each trial, the JSON attachment includes the simulator UUID/model and OS, workload, renderer and round; idle intervals, segment anchors and witness text, start/end offsets, individual active intervals in ms, and raw action timestamps in seconds on the Core Animation clock. An action's `observedValue` is the measured scroll offset in points or the measured UTF-16 caret location. The `ATTIC_PHONE_BENCH` log line gives that trial's summary:

- **Frame interval:** median and nearest-rank p95 of consecutive display-link timestamps during active segments only. Gaps between segments are never counted.
- **Input to refresh:** median and nearest-rank p95 of `1000 × (refreshAt − inputAt)` across the validated actions. Even-count medians average the two middle observations; p95 is the observation at one-based rank `ceil(0.95 × N)`.
- **Estimated missed frames:** sum of `max(0, round(intervalMS / idleMedianMS) − 1)` over active intervals. This estimates missing **callback opportunities** relative to that trial's measured idle cadence; it is not a compositor drop counter.

**Instrument limits.** A display-link tick and presentation geometry do not prove when pixels reached a display, or that the compositor painted each new glyph. Typing is an observed edit-to-refresh proxy, not physical key-to-photon latency. Simulator scheduling, host load and view/caret probes contribute overhead. Inputs are paced one at a time, not a fling, keyboard burst, IME session or touchscreen gesture. SwiftUI is exercised through the actual scroll view and editable text view it mounts; if a runtime stops exposing those public UIKit types or the expected geometry, the harness fails rather than substituting model mutations. A SwiftUI `TextEditor` may share Apple's UIKit text machinery. This compares these concrete fixture architectures: one editable paragraph among real read-only table views, not two complete rich-document engines, Attic's shipping editor, or persistence. Confirm any product choice separately on device at the planned stage.

## Accepting evidence

Record the integrated commit, Air/Xcode version, simulator model/UUID/runtime, configuration, keyboard setting, and `.xcresult` and log paths. Require **three executed cases, zero skips or failures, and 24 distinct JSON attachments** (3 workloads × 2 renderers × 4 rounds), with the action counts above. Compare each workload's paired rounds, reporting each renderer's median/p95 intervals and latency, raw sample counts and estimated misses. Retain all rounds and disclose interruptions or noisy idle baselines. An empty selector, a skipped test, a timed-out witness, or a partial set of attachments is not evidence for the full comparison. Do not substitute numbers from the fixture constants or treat a successful syntax parse as an Air run.
