# Smooth — memory and responsiveness investigation

Status: verified observer fix and investigation evidence delivered. Final fast and costs CI pass; local hosted-interaction and reveal gates remain red. The dominant spike allocation producer is identified and the caret-observer fix is verified; the exact private XCTest retaining graph and reveal repair remain unresolved. **Not an “absolutely smooth” acceptance claim.**

Worktree `/Users/taha/Developer/attic-px-mem`, branch `phase-x/smooth`.
The full measurement archive and captures are in `/Users/taha/Developer/attic-redesign-assets/phaseX/smooth/`; a copy of this report is in that directory's parent. Bare evidence filenames refer to that archive; `smooth/...` paths are relative to the assets `phaseX` directory.
Starting base `57c85724`; perf2 `c2814a94` merged first (`3dc361d8`).
Int11 `a1b663f3` merged before verification (`f88513cd`), then latest `e8f92570` merged again (`9d154bb6`) after its test-fixture/CI updates arrived. The second merge changes no application source. A third merge brings int11 `75d1dbfb` into `9f6d4121` (test/CI diagnostics only). The final merge `67129c00` brings int11 `d0801287`, including its production Undo-toast focus fix; a fresh fetch before final verification confirmed that endpoint. Latest verification is recorded below.
Local environment: macOS 27.0 (26A5425a), Xcode 27.0 (27A5252f), arm64.
Only the built-in display was connected; the requested external-display seam fell back to it.

## Changes and commits

- `a28728e1` — SM-04 probe teardown: recheck the exact owned executable immediately before bundle-ID quit; exited/replaced processes are left alone. Red ownership test failed on the unsafe quit, then all 12 smooth Python tests passed. Application code unchanged.

- `67129c00` — final int11 merge, including upstream `d0801287` (transient Undo buttons stay outside keyboard focus). This is the integration job's fix, not a smooth-authored performance fix.

- `8e9d030a` — SM-02 diagnostics: preserve page-in counts, distinguish sampled/stage-instrumented captures, reject requested-but-absent stages, rebuild a stale sampler binary. The experimental controller patch was removed; application source remains identical to `5cf4016d`.
- `75ad34a8` — SM-03: unregister dead caret indicators' block observers before dropping their tokens. Also handles the last indicator disappearing without a replacement. No focus, typing, caret geometry, store, or styling behavior changed.
- `ae84b7f5` — SM-01: independent weak layout/view lifetime measurements in the existing soak; a debug-only, phasex-only disk-backed Notes/Tasks control-plane workload; measured retention gates.
- `79412094` — match perf2's pre-reveal idle interval, turn frame monitoring off by default for reveal, record settings and reject comparisons with mismatched warm-up/instrumentation. Red test: five invalid comparisons wrongly accepted; green: all rejected.
- `4c5880e2` — wait for the owned preview process to exit before releasing its screen lock; independently tested asynchronous teardown.
- `5cf4016d` — SM-02: a paired cold-reveal comparison gate. It accepts no invented millisecond allowance: the median paired candidate-minus-reference difference must be <= 0.

## Findings ledger

| ID | Severity | Reproducer / expectation / observation | Disposition |
|---|---|---|---|
| SM-01 | P2 investigation | Twelve-note compressed-hour XCTest fixture; reported ~1.4 GB despite eight engines. Reproduced at 1.66 GB, with no attached editor layouts. | Allocation source attributed to XCTest backtraces; real disk workload separately measured. No speculative persistence/cache rewrite. |
| SM-02 | P2 investigation | Cold panel reveal reportedly 84–86 ms on colour1 versus 42–48 ms on 76e4276. | The matched 80-second-idle optimized pairs reproduce a slowdown: 174→275 and 63→125 ms. Gate fails. AppKit ordering dominates; a hidden key-loop preparation experiment failed the historical-base comparison and was rejected. No accepted reveal fix or defensible guilty-commit bisect. Initial frame-monitored probes were not the final verdict. |
| SM-03 | P3 | Replace 50 insertion indicators; expect every NotificationCenter block observer to be removed. Before: zero removed during replacements, only one removed at fitter teardown. | Fixed; 50/50 removals, zero orphaned registrations. |
| SM-04 | P3 / measurement issue | Type immediately after opening a note. Page keyboard restoration can move a programmatic end-caret into the title. | Probe now waits for restoration, sets first responder/caret, and verifies the exact resulting body text. Earlier mixed title/body runs excluded from typing comparisons. Production focus behavior left to the parallel focus work. |

## Memory: reproduce, attribute, separate

### Reproduction and allocation attribution

Fresh test process, the inherited 60-visit workload, one 5,000-line and eleven 200-line notes with tables:

| Checkpoint | Unpaused footprint bytes | Separate paused attribution run bytes |
|---|---:|---:|
| 15 | 172,230,096 | 246,924,728 |
| 30 | 718,898,880 | 1,089,210,000 |
| 45 | 303,138,712 | 306,202,472 |
| 60 | 476,153,944 | 1,661,192,232 |

These are independent diagnostic repetitions, **not a before/after speed or memory comparison**. All checkpoints retained eight engines and zero detached editor layout managers. Weak text-view counts were 2–5. The active session's undo history contained one grouped operation. In the final full-suite repetition after `9d154bb6`, the same checkpoints reached 1,024,675,392 / 235,245,336 / 1,331,449,816 / 1,457,213,424 B, again eight engines, zero detached layouts and one undo operation. The observer fix does not eliminate the unrelated XCTest spike.

`heap --noContent -s`, `vmmap -summary`, `leaks --noContent --nostacks`, MallocStackLogging and `malloc_history -callTree -noContent` were used against only this job's test host and isolated preview. Allocation logging adds footprint and CPU overhead; its runs are not timing comparisons. No Instruments trace/TOC/environment dump was produced. Summarized raw `sample`/allocation-stack traces were moved to Trash; the attribution excerpt and numerical summaries remain.

| Owner / allocation | Measured live allocation | Attribution / retention interpretation |
|---|---:|---|
| `_NSCallStackArray._frames` | 243,375 × 2,048 B = **498,432,000 B** | Dominant live heap allocation during a spike. |
| `_NSCallStackArray` objects | 243,375 × 48 B = **11,682,000 B** | Matching stack-array objects; together with frames, 96.5% of the 528,834,448 B sampled live heap. |
| XCTest Swift-error observer | 154,558 live stack arrays in a separate allocation-tree capture | `NoteJSON.init(from:)` attempts typed decodes; caught type mismatches call `swift_willThrow` → `XCTSwiftErrorObservation._installErrorObserver` → `NSThread.callStackReturnAddresses` → stack arrays. This observer is a test-runner component, not a shipping editor cache. |
| NoteBlock backing arrays | 4,128,768 B in the spike sample | The fixture's documents / warm engine contents, far smaller than the stack frames. |
| Autorelease-pool pages | 2,035,712 B in the spike sample | Consistent with transient test bookkeeping. The exact private XCTest retaining graph is not fully resolved; allocation stacks identify the producer. |
| TextKit paragraphs | 1,104 / 141,312 B in the same sample | Not the dominant allocation. Tracked detached engine layout managers: zero. |
| Later live heap snapshots | 13,976,640 B, then 10,196,928 B | Huge stack population disappears. One later snapshot had only 33 stack arrays. These file labels are capture-attempt labels, not synchronized phase numbers. |
| Test-host leaks | 440 / 21,472 B in the captured run | Orders of magnitude smaller than the footprint spike. |

Evidence excerpt: `smooth/allocation-attribution.txt`. Measurements and attribution excerpts are retained in the assets directory; raw heap/VM/leak and display-link reports are retained locally under `.build/smooth-raw`. Their environment was not printed. A retaining-tree sample of one of the small persistent stack arrays was **not** treated as proof of what retained the transient 243k population.

The large XCTest footprint is therefore unsuitable as a shipping-memory regression threshold. We did not suppress XCTest error observation, weaken decoding, or alter persistence to manufacture a lower number.

### Real app with an owned on-disk store

The optimized phasex preview runs the real SwiftUI Notes page, TextKit view, page controller, stores, save boundaries and Tasks mutations. Every launch gets a fresh owner-marked disk store accepted by the existing performance control plane. The legacy environment name `ATTIC_UI_TEST_CANVAS_PERSISTENCE=1` selects this on-disk store; **Canvas is never presented or exercised**.

Twelve notes, an 800×400 PNG and a 2×2 table in each, 60 visits, 40 real `keyDown` inputs per visit, and 60 task create/rename/complete operations. The long variant has one 5,000-line note; all others have 200 lines. This is accelerated use, not an elapsed human hour or an image-heavy library benchmark.

| Run | Footprint | Retention / limitations |
|---|---|---|
| 200-line disk allocation run | 161.3–284.9 MB over visits; hidden 171.2 MB | MallocStackLogging enabled. Eight warm engines, one attached engine layout, 1–3 live tracked views. Early harness allowed mixed title/body input; useful for attribution, excluded from body-typing comparison. |
| Long-note exploratory run | 94.9–218.5 MB over visits; hidden 109.0 MB | No allocation logging; same mixed-input limitation. |
| Corrected long-note body-input baseline | Peak **210.5 MB**, hidden **102.0 MB** | 60 verified visits; eight engines, one attached layout, two tracked views after warm-up. Exact body result checked after each visit. |

The allocation run's 15-visit live heap was 64,198,541 B: Swift metadata ~6.95 MB, SwiftUI PropertyList ~5.39 MB, purgeable image storage ~5.18 MB, AttributeGraph ~2.64 MB and closure contexts ~1.56 MB. At 30 visits: eight NoteEditorEngines (~20 KB objects, excluding backing storage), eight undo operations, three NoteEditorTextViews, three SwiftData ModelContexts. Framework-wide NSTextLayoutManager count included 17 managers (table cells and field editors included); the engine-owned attached count was one. No `_NSCallStackArray` class appeared in the final app heap.

App `leaks`: 416 / 26,400 B at seed, 15, 30, 60 and hidden; 420 / 26,528 B at 45. This tiny transient variation and unchanged endpoint do not explain a growing gigabyte working set. It is not a claim that all framework leaks were fixed.

After the corrected baseline process exited, a read-only SQLite check of that run's owned store confirmed twelve notes, each with all **200 appended body characters**, unchanged synthetic title, and one image; all sixty tasks retained the renamed title and Done status. See `smooth/disk-readback.json`.

The fixed allocation run completed all sixty verified body-input visits: **269,763,760 B peak / 171,394,272 B hidden** with MallocStackLogging. At both visit 30 and hidden, heap showed eight engines, eight undo operations, two NoteEditorTextViews and three ModelContexts; no `_NSCallStackArray` class. Leaks were 417 / 26,496 B at seed, 15, 30, 60 and hidden, briefly 422 / 26,656 B at 45. No growing endpoint leak was detected. This is an attribution run, not a timing or footprint-improvement comparison with the earlier mixed-input allocation fixture.

Source ownership agrees with those counts: `NotesPageController.cache` owns clean warm sessions (limit eight); each session owns its engine, attributed storage and undo history; attachments in that storage own their rendered NSImages. `NoteUndoHistory` bounds its operation count at 500, but that is not a byte bound. Store services retain their ModelContexts. Detached engine TextKit layout managers are released. Decoded image bytes across image-heavy warm notes remain an unmeasured risk; one synthetic PNG per note does not bound every possible document.

### Actual retained-memory fix and regression gates

`NoteCaretFitter.watch` previously filtered dead weak indicators out of its dictionary without calling `removeObserver` on their block tokens. NotificationCenter retains block registrations until they are removed. Removing the dictionary entry also lost the token needed for teardown.

The locked red test observed 50 registrations, zero removals during replacements, and only one removal at teardown: **49 orphaned registrations**. The fix prunes and unregisters dead observations in `refresh`, including when no replacement exists. Green: **50 registrations / 50 removals, zero orphaned registrations**. The test uses an independent counting NotificationCenter and asserts each synthetic indicator really deallocates. This small, real lifetime bug is **not** the cause of the XCTest gigabyte spikes.

Gates:

- `PhaseXCaretTests.testSmoothRetiredCaretObserversAreUnregistered`: exact lifetime accounting; red before, green after.
- Existing compressed-hour engine test now also asserts **zero retained detached engine layout managers**, observed in repeated baselines.
- `Scripts/smooth_probe.py`: exactly 60 ordered visits, <= **8 live engines**, exactly **1 attached layout**, and the expected completed task count after each visit. Bounds come from measured app runs and the existing clean-session cache limit. No invented footprint threshold.
- Python tests reject incomplete/reordered workloads, retained extra engines/layouts, invalid reveal data and a slower paired candidate.

### Clean interleaved before/fixed repetitions

Production-before app: `3dc361d8` plus the identical corrected diagnostic workload. Fixed app: `5cf4016d` (includes latest int11 application source). All four runs use the long-note variant, no allocation logging, fresh disk stores, the same display/corner and real body key inputs. Adjacent pairs reverse order: **B2 → A2, then A3 → B3**. No local xcodebuild/test job overlapped these four screen probes. Other jobs can still load the shared Mac.

| Pair / order | Before peak / hidden MB | Fixed peak / hidden MB | Before key-call median / p95 ms | Fixed key-call median / p95 ms | Before / fixed first Notes ms |
|---|---:|---:|---:|---:|---:|
| B2 → A2 | 173.770 / 122.308 | 205.358 / 106.677 | 3.348 / 12.316 | 2.242 / 9.897 | 260.577 / 297.760 |
| A3 → B3 | 214.894 / 108.316 | 213.993 / 102.991 | 3.177 / 9.614 | 2.314 / 10.908 | 219.925 / 222.644 |

Decimal MB. Before/fixed peak spreads: **41.124 / 8.634 MB**; hidden spreads **13.992 / 3.686 MB**. Key-median spreads **0.170 / 0.073 ms**, p95 spreads **2.702 / 1.011 ms**. Eight engines / one attached layout after warm-up, sixty completed task mutations and 2,400 verified body inputs in every run. The fixed endpoint was read back after exit: all twelve notes retain 200 appended characters and one image, and all sixty renamed tasks are Done (`fixed-disk-readback.json`).

This does **not** demonstrate a broad memory or responsiveness improvement. Key-call medians are lower but p95 changes direction between pairs, and cold Notes is slower in both fixed samples. The paired build also includes integration changes; attributing timing differences to the tiny observer fix would be unjustified. Total process CPU seconds: before **44.975 / 40.817**, fixed **41.680 / 40.134** (spreads 4.158 / 1.546 s).

Key-to-commit p95: before **23.035 / 18.412 ms**, fixed **19.817 / 20.411 ms**; fixed B3 has a **608.964 ms maximum**, versus 59.441 / 55.873 ms before. StoreSave maxima: before **26.404 / 16.912 ms**, fixed **13.165 / 189.031 ms**. Full-workload display-link gaps >250 ms: before **5 / 3**, fixed **5 / 7**. B3's tails are retained, not discarded as presumed machine noise. They require controlled follow-up; no causal stack capture coincides with that exact outlier. See `smooth/clean-pairs-summary.json` and each run's measurements.

The first A1/B1 repetition overlapped a local fresh-process test-isolation run. Its retention evidence is retained, but its timing is excluded. This exclusion was made before the replacement clean AB pair, not because of its result.

### Hidden-idle cost

The same matched reveal launches include a 60-second hidden-idle window after their 20-second settle, with no frame monitor. Base CPU: **3.440 / 1.691 ms**, interrupt wakeups **3 / 1**. Fixed CPU: **1.144 / 3.184 ms**, interrupt wakeups **2 / 4**. All four recorded **zero package-idle wakeups**. Fixed footprint changed by −49,152 / −671,768 B across the window. CPU spreads: base 1.750 ms, fixed 2.040 ms. These are tiny measured idle costs, not a claimed causal improvement; they do not support a continuously busy background loop in this configuration. See `hidden-idle-summary.json`.

## Reveal

Same identity, fresh owned empty stores, same display/corner, no allocation logging. These initial runs used a 2-second settle and enabled the frame monitor. Adjacent AB/BA launches; timings are `PanelRevealToOrderedFront`, not input-to-displayed-pixel latency.

| Configuration | Order | 76e4276 base ms | Current inherited behavior ms |
|---|---|---:|---:|
| Optimized Local | A then B | 41.431 | 37.058 |
| Optimized Local | B then A | 26.206 | 20.219 |
| Debug Local | A then B | 33.951 | 20.851 |
| Debug Local | B then A | 22.771 | 21.092 |

Optimized spreads: base 15.225 ms, current 16.839 ms; median paired difference **−5.180 ms**. Debug spreads: base 11.180 ms, current 0.241 ms. This configuration did not reproduce perf2's 84–86 ms result; it does not yet match perf2's roughly 80-second pre-reveal idle interval. No source change was made to reveal or colours, and no causal reveal speedup is claimed. The UI-test runtime uses scratch defaults, so an owner’s appearance or panel settings are not imported into these comparisons.

Historical source was extracted from `git archive 76e4276` into this worktree's `.build/reveal-base`; its launcher manifest reflects the current checkout, so the explicit archived source revision is the authority. The immutable optimized reference copy is `.build/AtticRevealBaseOptimized.app`. Configuration and executable identity are kept separate from that archive revision.

A useful bisect requires a reproducibly bad endpoint. Do not label design1, colour1 or owner1 guilty from the original two samples alone. The paired gate now preserves the comparison and spread for future regression checks.

### Historical endpoint and instrumented gate

The subsequent historical debug AB/BA comparison was **35.538 → 17.756 ms**, then **17.937 → 15.999 ms** (76e4276 → colour1 4b25a1fa). Spreads: base 17.600 ms; colour1 1.757 ms. Both source endpoints were freshly archived/built in this worktree. These short-settle, frame-monitored launches did not reproduce the 84–86 ms endpoint; the matched-idle follow-up below is required before drawing a broader verdict.

Frame-monitor-enabled optimized base → fixed pairs: **17.949 → 18.830 ms**, then **32.694 → 20.603 ms** in reversed launch order. One pair is 0.881 ms slower, the other 12.091 ms faster. Base spread 14.745 ms; fixed spread 1.773 ms. Median paired difference **−5.605 ms**: this instrumented measured-relative gate passed (`smooth/final-reveal-gate.json`). These spreads prohibit attributing a speedup to the unrelated caret-lifetime fix.

One initial historical sequence stopped before its second launch because LaunchServices still reported the previous preview during asynchronous quit. Its first result (27.897 ms) is retained and excluded from the paired gate. `4c5880e2` makes the driver hold the screen lock until its own verified executable exits, with timeout and PID-reuse protection; the complete fresh sequence then succeeded. This is a harness cleanup fix, not app performance code. No second fast/costs CI dispatch was made for the later Python-only probe changes; its focused tests passed locally.

### Matched idle follow-up

Review of perf2's recorded timestamps showed about 80 seconds from coordinator startup to reveal (20-second settle plus a 60-second idle sample). The initial smooth launches instead waited 2 seconds with the display-link monitor enabled. The follow-up disables that monitor, waits 20 seconds, samples an additional 60 seconds, then reveals once. The driver now records those settings explicitly and defaults reveal probes to **no frame monitor**; soak probes keep their monitor. Historical debug base → colour1 results are **226.003 → 192.673 ms**, then **151.311 → 183.664 ms** in reversed order. Spreads: base **74.692 ms**, colour1 **9.009 ms**. Paired differences change direction (**−33.330 / +32.353 ms**); the second pair was separated by a roughly 5.6-minute shared-screen-lock interval. This is not a stable bad endpoint for a causal bisect. Matched optimized base → fixed pairs are **173.767 → 274.728 ms**, then **62.918 → 125.427 ms**. Both pairs are slower: **+100.961 / +62.509 ms**, median **+81.735 ms**. Spreads: base **110.849 ms**, fixed **149.301 ms**. The corrected no-slower gate **fails**. This remains an open regression after the attribution/experiment below; the earlier instrumented pass does not supersede it. This methodological correction is `79412094`; nine Python gate tests pass, including rejection of differently instrumented/warmed captures. No claim that the timing setup explains the original candidate-versus-reference difference is made.

### Stage attribution (optimized, matched idle)

All three archived/current binaries received the same opt-in stage timestamps, written only after the measured ordered-front interval. Order: **base → colour1 → current**, then **current → colour1 → base**; each triple held the screen lock continuously. This is bracketed comparison, not immediately adjacent base/current pairs.

| Source | First / reverse reveal ms | First / reverse order-front stage ms |
|---|---:|---:|
| 76e4276 | 115.365 / 105.306 | 107.718 / 91.991 |
| colour1 4b25a1fa | 115.805 / 65.481 | 107.870 / 58.981 |
| current 79412094 (same app source as 5cf4016d) | 172.391 / 101.160 | 138.432 / 88.003 |

Colour1 minus base changes direction (+0.439 / −39.825 ms). Current minus base also changes direction (+57.026 / −4.146 ms), but its median delta remains +26.440 ms and fails the no-slower gate. These runs do not identify a reliably bad historical commit for a valid causal bisect. They do locate the main cost inside AppKit ordering rather than page construction (0.04–0.57 ms in these current runs).

A separate one-second `sample` probe captured only three main-thread samples and perturbed the reveal to 1,331.774 ms; it is excluded from performance comparisons. All three samples pass from `makeKeyAndOrderFront` through native first-responder/key-loop setup into `NSHostingView.updateEnvironment` / `NSAppearance.apply`. That is a hypothesis-producing stack, not a reliable percentage breakdown. The source excerpt remains in `reveal-profile-current/stack-summary.txt`; the raw trace was moved to Trash. A same-binary opt-in experiment tests explicit native key-loop preparation during the existing one-shot hidden Tasks warm-up, retaining automatic key-loop recalculation and never making the panel key.

### Hidden key-loop preparation experiment — rejected

The diagnostic-only candidate called `recalculateKeyViewLoop()` once after the existing hidden Tasks page build. Automatic recalculation remained enabled; no window was ordered or made key. The same optimized binary toggled only `ATTIC_REVEAL_PREPARE_KEYS`, with the same 80-second idle and no frame monitor.

| Pair | Control ms | Preparation enabled ms | Candidate minus control ms |
|---|---:|---:|---:|
| A1 → B1 | 285.865 | 251.140 | −34.725 |
| B2 → A2 | 123.245 | 65.243 | −58.003 |
| A3 → B3 | 174.718 | 222.980 | +48.262 |
| B4 → A4 | 530.386 | 182.496 | −347.889 |

The same-binary median paired delta is **−46.364 ms**, but spreads are **407.140 / 185.897 ms** and the first confirmation pair regresses. More decisively for the requested goal, the historical-base brackets remain slower in both directions: **168.317 → 222.980 ms**, then **125.927 → 182.496 ms**. Median delta **+55.617 ms**, spreads **42.390 / 40.484 ms**: the no-slower-than-base gate fails. Confirmation order was base → control → candidate → candidate → control → base, held under one screen lock; baseline comparisons are brackets, not adjacent pairs.

The hidden preparation calls cost **0.933–1.181 ms**. Initial reveal-to-one-second-later CPU deltas and page-ins were mixed (222→326 / 236→214 ms CPU; 2,556→3,801 / 1,692→590 page-ins). These results do not establish a cause-level repair. **No production warm-up or focus change was retained.** The diagnostic patch and executable hashes remain for reproduction; they are not shipped app code. Stage recording requires that diagnostic patch; a normal preview does not emit those stages, and the comparison gate now rejects a requested-but-missing breakdown (old gate red, new gate green).

Source inspection: the real hover approach holds `.userInitiatedAllowingIdleSystemSleep` near the corner; the far-pointer signal probe moves directly from hidden idle to the visible/event-driven cadence. [Apple documents](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html) that foreground/event delivery differs from background App Nap scheduling. No App Nap state was measured here, so attributing this regression to App Nap would be speculation. No sleep setting or background activity policy changed.

### Final post-merge confirmation

A fresh AB/BA sequence compared the same archived optimized historical base with optimized `67129c00`, after the full local tests finished. Both used 20 seconds settle plus 60 seconds idle, no frame monitor, and separate owned disk stores under the screen lock. Reference → final: **52.849500 → 42.294541 ms**, then **40.066042 → 98.250792 ms** (second pair ran final first). Paired differences **−10.554959 / +58.184750 ms**; median **+23.814896 ms**, so the no-slower gate **fails**. Reference spread **12.783458 ms**, final spread **55.956251 ms**. This confirms that the latest integration does not meet the requested gate; it does not establish a stable guilty commit. `postmerge-reveal-gate.json` and the four `postmerge-reveal-*` measurements retain every result. Final app identity/hash: `postmerge-source.json`.

**Reveal disposition:** the long-idle regression is reproduced, the dominant stage is identified, and the tested warm-up hypothesis did not meet the base gate. A stable bad historical endpoint sufficient to blame design1/colour1/owner1 was not established. The requested reveal fix/bisect is incomplete; the orchestrator's quiet on-screen gate remains necessary. Neither the short-settle pass nor the rejected experiment is an acceptance substitute.

## Remaining jank: measured ranking and UI coverage

| Rank | Area / observation | Measured evidence | Action / remaining limit |
|---:|---|---|---|
| 1 | Cold panel reveal after hidden idle | Earlier matched pairs 174→275 / 63→125 ms; final post-merge pairs 52.85→42.29 / 40.07→98.25 ms, median paired +23.81 ms. Earlier stage probes put most time in AppKit ordering. | No accepted fix. Native key-loop preparation failed both later historical-base brackets; a defensible guilty-commit bisect remains open. Warm reveals in the corrected soak were ~0.95 ms median / 1.78 ms p95. |
| 2 | Cold Notes page / long-note layout | Corrected baseline first Notes `PageSwitch` 261.8 ms; active sample includes native hosting/TextKit layout. | No isolated cause-level production fix established. Seeding and first 5,000-line layout are distinct from steady typing. |
| 3 | Accelerated body typing and commit tails | Corrected baseline 2,400 calls: median 1.908 / p95 7.027 / max 21.513 ms. Clean fixed B3 later has a 608.964 ms commit-marker maximum. | Tails remain; no causal stack coincides with that outlier. Some keys coalesce under the single pending signpost. Commit marker is not scan-out. |
| 4 | Save boundaries / task mutations | Corrected baseline 312 saves: median 0.641 / p95 3.683 / max 13.076 ms; later fixed B3 max 189.031 ms. | Durable disk readback passed. Save preparation outside this signpost and the rare tail remain unisolated. |
| 5 | Long-lived caret observations | 49 orphaned registrations per 50 indicator replacements before; zero after. | Fixed with exact count gate. No unmeasured typing speedup or gigabyte reduction claimed. |

The corrected accelerated run recorded 10,546 display-link callbacks, median gap 8.33 ms, p95 16.67 ms, maximum 1,144.94 ms; 111 gaps >50 ms, five >250 ms. These include launch, fixture generation, cold note opens, all actions and shared-machine interference. They show main-thread/display delivery stalls in the workload, **not 111 typing hangs or proof of an app-only cause**. An 8-second main-thread sample contained 3,332 samples: native key handling 524, panel-host layout 529, text-view layout 176; these are overlapping stack counts, not additive percentages. Test instrumentation logs frames and is not normal hidden-idle behavior.

Targeted on-screen baseline coverage (screen lock held, optimized phasex only): long Tasks scroll, view-options menu, task rename with visible readback, Tasks Find reducing to the renamed row, Tasks→Notes switch, table-cell Find showing 1/1, Format/Aa opening in the matching table cell, and date-picker opening. Captures: `smooth/tasks-before.png`, `smooth/notes-before.png`. An attempted edge drag did not establish a resize; it is **not** counted as F-14 verification. The final controlled-width check is described below.

Final native checks used the exact optimized fixed executable while holding the screen lock. Tasks: priority shortcut produced the Low priority state/toast, Command-D created a second row, Command-Z removed the duplicate, and the long list scrolled to its end. Notes: typed ` smooth` after the fixture's final word, read the exact text back, Command-Z restored it, and table Find `network` displayed **1 / 1**; Escape selected the matching table cell and exposed the formatting bar. The first priority press immediately after leaving inline rename did nothing; the second press worked. This isolated first-input observation is not a resolved regression or proof that the offscreen fixture failure is harmless.

F-14 functional resize check: the existing scratch-settings seam changed Tasks **320 → 520 → 320 → 420 pt**. Captures show title truncation and tag compaction updating, due dates aligned, controls retained, and the same task rows. Files `tasks-fixed-width520.png`, `tasks-fixed-width320.png`, `tasks-fixed-width420.png` are the actual observed widths. This checks reflow through the production settings resize path, not continuous live-drag frame pacing. Three-second display-link windows around the scheduled widths had maximum gaps **131.80 / 694.03 / 39.51 ms**, with **2 / 3 / 0** gaps over 50 ms. The 320 pt window overlaps native menu interaction; these are observed callback gaps, not an isolated resize-cost benchmark (`resize-frame-windows.json`). An initial attempt omitted the non-key-reveal branch required by this seam; those unchanged-width images were not accepted as resize evidence. Notes' fixture title still visually overlaps the floating header at the top; this pre-existing visual issue is recorded, not claimed fixed.

The long orchestrator fair gate was not run. “Every source of jank fixed” is not supported by this bounded hunt. Large image libraries, human-paced elapsed-hour use and first-frame latency beyond the existing readiness markers remain broader validation work.

## Verification

Final checks, application source `67129c00`, diagnostic scripts `a28728e1`:

| Check | Outcome |
|---|---|
| Local strict build | Pass |
| Local full headless | 2,557 passed / 27 skipped / 12 failed; 2,596 total |
| Local native subset | 11 passed / 1 skipped / 1 failed |
| Fresh isolation of all broad-run failures | 4 passed / 8 failed |
| Final fast CI | Pass; 2,586 unit tests passed / 10 skipped / 0 failed; separate dropdown timing 3/3 |
| Final costs CI | Pass; 65 unique rows accepted, one prescribed recheck |
| Final paired reveal gate | Fail; median paired +23.815 ms |

Earlier and focused verification evidence follows; it does not replace these final outcomes.

- Red observer test: failed exactly on missing removals; one test / two assertions.
- Caret + NoteEditorEngine suites: **72 passed, zero failed/skipped**.
- Python smooth gates: **12 passed** (includes asynchronous owned-preview teardown).
- Python cost plumbing: **44 passed**.
- Project-generation verification: **passed**, repeatable/current; no project inputs changed.
- Earlier `a1b663f3` headless suite: **2,562 passed / 25 skipped / 8 failed**, 2,595 total, exit 65. Xcode restarted after the fixture crash and ran the remaining tests. Uses CI's documented debug exclusions for the three optimized cost suites; those run in the requested costs lane. This broad run did not opt into key-window fixtures; a separate final native-fixture run explicitly opts in under the screen lock. No system keyboard setting was changed.
- Strict Local build: **passed**, including the latest `8e9d030a` post-merge invocation; independent strict CI build passed.
- Optimized fixed preview: **built and exercised**, application source `5cf4016d`, executable SHA-256 `2203bff3d3177a4c8acd687797ea792c9710fb4362f0fe46639ebca6b28e9855`, no debug dylib. Completed paired disk/reveal probes and native UI checks. Later `9d154bb6` changes only upstream fixtures/workflow, not this app binary.
- Fast CI [38105488911](https://github.com/TesterPen0812/Attic/actions/runs/38105488911), dispatched once on `5cf4016d`: **failed**. Strict build succeeded; 2,581 unit tests passed, nine skipped, five failed. New observer gate passed. All five failures are `NotesKeyboardUndoTests`: the inherited `025231dc` fixture failed its genuine `window.isKeyWindow` / `NSApp.keyWindow` assertions, with downstream Undo/delete assertions. We did not remove or weaken those assertions. The latest base itself, `a1b663f3`, failed the same five tests in [int11 run 38104419843](https://github.com/TesterPen0812/Attic/actions/runs/38104419843), plus an accessibility dropdown timing test that passed on smooth. Thus these five failures are confirmed inherited; they remain unresolved, not green gates.
- Costs CI [38121211019](https://github.com/TesterPen0812/Attic/actions/runs/38121211019), dispatched once on `5cf4016d` after fast finished: **passed**. All **65 comparison rows** passed on their first attempt; independent absolute/functional budgets also passed. No cancellation overlap, extra dispatch, changed limit or recheck was needed. The prior perf2 failing `done-key-8` row passed at 4.619 ms reference / 4.968 ms candidate against the current 13.295 ms variability-derived bound. This green gate is not a causal fix claim for perf2's prior result. Ledger: `smooth/costs-ci-ledger.md`.
- The local full run spans a several-hour wall-clock discontinuity (03:3x → 08:22 local time). Its timing samples are not a valid uninterrupted performance comparison. It is still a test execution whose failures must be reported; selected failures were rerun as described below.

- Earlier complete headless suite after merging `e8f92570` (`9d154bb6`): **2,568 passed / 25 skipped / 1 failed**, 2,594 total, exit 65. The one failure is the existing Tab-visibility case: row 18 at y = −56. All seven other failures from the earlier broad run passed this time. This uses the latest workflow's separate native-timing lane; those three dropdown tests and five updated Notes Undo tests run separately below.

- Earlier native-fixture invocation under both build and screen locks: **7 passed / 1 failed / 0 skipped**. All three dropdown timing gates passed. Four of the five updated Notes Undo tests passed; `testAToastThatDoesNotClaimTheKeyLeavesCommandZToTheText` still failed the editor-first-responder and text-Undo assertions. All five now had real `window.isKeyWindow` and `NSApp.keyWindow` ownership, so this remaining failure is distinct from the older fast-CI fixture failure. It is unresolved; the new fixture and the whole branch are not declared green.

### Latest integration and rejected viewport experiment

Final application source is `67129c00`; script-only teardown hardening is `a28728e1`. Post-merge strict build **passed**. The final full headless run completed **2,557 passed / 27 skipped / 12 failed**, 2,596 total, exit 65. Xcode restarted after a missing-row-frame force unwrap at `TasksRound6Tests.swift:49` and completed the remaining tests. `postmerge-failures.md` lists the failed cases; `postmerge-verification.json` preserves the complete result.

The separate screen-locked native invocation had **11 passed / 1 skipped / 1 failed**, 13 total. All three dropdown timing cases, Notes Undo, ordinary Tab/Shift-Tab and priority shortcuts passed; the long/filtered viewport case still failed at row 18, y = −56. The skipped case requires the dedicated native FKA lane.

The file-tile TIFF comparison passed alone (**1/1**) with its original byte-for-byte assertion; the broad-run failure remains recorded and its cause is unproved (`file-isolation-verification.json`).

Fresh-process isolation of all 12 broad-run failures, under the screen lock with the key-window opt-in, finished **4 passed / 8 failed / 0 skipped**. Eight failures persist: drag-out; Command-F on Done; ordinary Tab traversal; Add Subtask via the actions menu; a highlighted submenu command; long/filtered viewport visibility; Tasks page restoration; and text Undo after a task-menu change. The file-tile comparison, Done-row click/restore, highlighted Start Working menu case, and bottom-stack click shielding passed. These results do not make the full suite green. Details: `failures-isolated-verification.json`. No production or fixture patch was retained for these unresolved cases. No claim is made that all failures are environmental or inherited.

The required int11 merge imported production code after the original fast/costs pair, so a final changed-source fast run [38131251632](https://github.com/TesterPen0812/Attic/actions/runs/38131251632) was dispatched. It **passed**: strict build, unit tests (**2,586 passed / 10 skipped / 0 failed**, 2,596 total), all three separate native dropdown timing gates, and static analysis. Exact unit summary: `postmerge-ci-unit-summary.json`.

The final costs run [38134603830](https://github.com/TesterPen0812/Attic/actions/runs/38134603830) was dispatched only after fast completed and **passed**. All **65 unique comparison rows** passed under the unchanged protocol; one row required the prescribed same-job recheck (66 ledger entries total). The independent budget checks passed. No bound, row, oracle, or recheck rule changed. Full attempt ledger: `smooth/postmerge-costs-ci-ledger.md`; exact run metadata: `smooth/postmerge-ci.json`. This green costs lane does not supersede the failed local reveal gate or local hosted-interaction results. These are explicitly additional dispatches for the changed integration, not retries of an unchanged failing result; the original pair remains reported above.

At `8e9d030a`, strict passed; the complete headless invocation had **2,566 passed / 26 skipped / 3 failed** (2,595 total). Failures were the two existing Tab cases and the priority-shortcut case. A separate native invocation passed **9/9** with zero skips. A fresh-process, screen-locked isolation passed ordinary Tab/Shift-Tab/Return and all priority shortcuts, but reproduced the long/filtered viewport case at **row 18, y = −56**. Thus the other two failures are context-dependent observations, not proved environmental failures or fixed defects. See `latest-verification.json` and `tab-isolation-verification.json`.

After importing `d0801287`, a bounded viewport hypothesis used an explicit top anchor when a known focused-row frame was above the viewport. The focused check had **3 passed / 1 failed**: the identical −56 result remained. The experiment was rejected and all production/test edits restored before final verification. `viewport-experiment.patch` preserves the hypothesis; `viewport-focused-verification.json` preserves the failed check. It is not shipped and no assertion was weakened.

The imported toast change has upstream FKA passes [38128761331](https://github.com/TesterPen0812/Attic/actions/runs/38128761331), [38129122649](https://github.com/TesterPen0812/Attic/actions/runs/38129122649), and [38129466616](https://github.com/TesterPen0812/Attic/actions/runs/38129466616). This is upstream coverage of `d0801287`, not a claim that smooth independently dispatched three FKA runs.

The optimized `67129c00` preview visibly applied **Low → High → None** to Call the plumber while retaining its row focus, including the transient toast. `final-priority-shortcuts.txt` and `tasks-final-toast-focus.png` record that route. A later attempted composer click did not reset focus: the recorded 18-Tab walk began at the previously focused fifth row, traversed the remaining rows, wrapped through the composer, and ended on row two. `tasks-final-tab18.png` is therefore not proof of the eighteenth row's visibility. The subsequent capture failed with `cgWindowNotFound`; no claim of viewport acceptance is made. The owned process was quit by its bundle ID and verified exited before releasing the screen lock.

### Local failure accounting

The full run's eight failed tests were Tab viewport visibility, drag-out, priority shortcuts, Command-F during swipe, Escape/Command-Z in subtasks, Command-D duplicate, Tasks page restoration, and Done row click selection. The last fixture crashed at `TasksRound6Tests.swift:49` after finding no row frames; Xcode restarted the test host and completed the rest. No production-app crash was observed.

A fresh-process three-test rerun passed drag-out and reproduced Tab viewport visibility and priority shortcuts. This rerun overlapped the first on-screen before workload, so it is not an isolated-screen diagnosis of the priority route; that first timing pair is excluded from timing conclusions. No claim is made that sleep explains all failures. Tab's exact −56 pt result was also documented by perf2 before this job. Final on-screen actual-user-route checks are reported separately.

## Bounded-hunt disposition

The prescribed [attic-bug-hunt skill](/Users/taha/.agents/skills/attic-bug-hunt/SKILL.md) limits a cluster to about two hours and says, “Past that, write up what you learned and move on.” Repeated paired runs identified the reveal stage but did not establish a stable guilty commit; the key-loop and viewport hypotheses failed their verification. Their patches were removed and their evidence retained. The requested reveal repair, exact private XCTest retaining graph, and remaining failing hosted interactions are incomplete. This branch is not a smoothness acceptance claim; the orchestrator's reserved quiet fair gate remains unrun by this job.

## Boundaries and provenance

Protected owner identities were not launched, quit, captured, or opened for plist/data access. Exact phasex executable paths and control-plane PIDs are checked; executable-name matching is unsafe because another preview can share the same process name. Only this job's owned fixture stores are used. No other worktree, system setting, CloudKit entitlement or iPhone behavior changed. No subagents. Full headless tests include existing Canvas unit coverage by suite membership; manual UI checks and custom performance probes exclude Canvas.

The advertised Hindsight tools were absent from the callable tool inventory. Architecture and decisions were grounded in current source, AGENTS.md, perf2's report and the owner/orchestrator records. No Hindsight writes were attempted.

Measured active output is **2.52 GB** in total, including `.build`, both evidence copies, the 58 recorded owned stores and owned `/tmp` files, below the 3 GB cap (`smooth/final-disk-usage.json`). Read xcresults are summarized then moved to Trash. Evidence summaries and captures live here; raw profiling files are not required for app operation.

## Reproduction commands

Use the prescribed optimized local-only preview build and a fresh, absent output directory for each launch. Run only while the phasex identity is free; the driver refuses to close an existing preview. Reverse A/B order in adjacent comparisons.

```sh
/usr/bin/lockf -k /tmp/attic-screen.lock python3 Scripts/smooth_probe.py \
  --app .build/AtticSmoothFixed.app --mode soak --long \
  --output .build/smooth-new-soak
# Add --allocations only for attribution; do not compare its timings.
/usr/bin/lockf -k /tmp/attic-screen.lock python3 Scripts/smooth_probe.py \
  --app .build/AtticSmoothFixed.app --mode reveal --settle-seconds 20 --idle-sample-seconds 60 --no-frame-monitor \
  --output .build/smooth-new-reveal
python3 Scripts/smooth_reveal_gate.py \
  --pair phaseX/smooth/matched-reveal-base-optimized-A3/measurements.json phaseX/smooth/matched-reveal-fixed-optimized-B3/measurements.json \
  --pair phaseX/smooth/matched-reveal-base-optimized-A4/measurements.json phaseX/smooth/matched-reveal-fixed-optimized-B4/measurements.json
python3 -m unittest discover -s Scripts -p 'test_smooth*.py'
/opt/homebrew/opt/ruby/bin/ruby -rbundler/setup Scripts/verify_project_generation.rb
```

The archived source reference and before-app hashes are in `smooth/provenance.json`; do not substitute an owner's installed preview. The inherited perf2 changes and their prior cost failure are documented in `/Users/taha/Developer/attic-redesign-assets/phaseX/perf2-report.md`.
