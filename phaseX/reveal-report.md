# Reveal — panel ordering regression

Worktree `/Users/taha/Developer/attic-px-mem`; branch `phase-x/reveal`, created from `origin/phase-x/smooth` (`a9745a53`). Product fix `e610deda`; diagnostic/gate tooling `8f132385`. The paired timing gate passes. The matched count gate also passes. Fast and costs CI passed on `8f132385`. Interactive composer UAT is blocked by the native automation pipe.

Normal corrected preview: `/Users/taha/Developer/attic-px-mem/.build/RevealFixed.app`, executable `Contents/MacOS/AtticPhaseX`, bundle `com.taha.Attic.preview.phasex`, code commit `8f132385`. The historical preview is `.build/RevealBase.app` from archived `76e42765`. Both are optimized, ad-hoc signed Local builds with `ATTIC_LOCAL_ONLY`; executable hashes are recorded in `reveal/timing-provenance.json`. Source archives inherit the parent checkout's Git label in launcher output, so the explicit archive revisions in the count manifest, rather than that label, establish historical provenance.

## Cause and change

The extra work is three native list-mask wrappers, not a multiplication of hosting roots or environment propagation. `b6b74ddb8ec20dfc9a13e8b3e6443be36540fb62` (F-13, rows overlapping the composer controls) adds a second `.mask` around each of the three Tasks lists. It is absent from owner1 and present in the int11 endpoint integrated into smooth. Native hierarchy counts rise from 65 views / 36 backing layers to 68 / 39; all three added views are `SwiftUI._NSGraphicsView` instances.

`TasksListEdges` now composes the plain-controls mask inside the existing mask and applies the result once to the list. The alpha product, live composer-height observation, faint edge treatment, scroll margins and native scrolling content are preserved. There is no conditional branch that remounts the scroll view. No key-loop preparation, focus, activation, appearance, palette, tag-colour, persistence or synchronization code changed.

The red native regression test measured two graphics views and six backing layers against the reference's one and five. After the fix it passes. A separate test changes the composer mask height and verifies the same `NSScrollView` and scroll offset survive. The existing rendered F-13 test still verifies that rows are excluded beneath the plain Date / Tag / Priority strip.

## Counts and method

Every accepted count capture uses an optimized local-only phasex preview, a new owner-marked disk store, Tasks only, external-display selection with built-in fallback, no frame monitor, 20 seconds settling plus 60 seconds idle. All screen runs hold `/tmp/attic-screen.lock`. The diagnostic overlay is applied only to source archives in this worktree's `.build`; it is never linked into the normal shipping preview.

The overlay walks the actual panel's native view hierarchy, records native key-window state, follows `nextKeyView`, and counts main-thread Objective-C appearance/environment callbacks and explicit `CATransaction.commit` calls. LLDB additionally resolves exactly one native function location each for `SwiftUI.NSHostingView.updateEnvironment()`, `NSAppearance.apply(to:...)` and `CA::Transaction::commit()`. Their breakpoints are enabled only between the diagnostic ordering markers, then disabled and detached. Debugger-counted timings are excluded from the timing gate.

| Revision | SHA | Hosting roots | Native views | Backing layers | Key-loop views | Native env / appearance / CA commits |
|---|---|---:|---:|---:|---:|---|
| Historical base | `76e42765` | 1 | 65 | 36 | 32 | 1 / 1 / 0 |
| design1 | `890071ae` | 1 | 65 | 36 | 32 | 1 / 1 / 0 |
| colour1 | `4b25a1fa` | 1 | 65 | 36 | 32 | 1 / 1 / 0 |
| owner1 | `5d508588` | 1 | 65 | 36 | 32 | 1 / 1 / 0 |
| int11 integrated into smooth | `d0801287` | 1 | 68 | 39 | 32 | 1 / 1 / 0 |
| smooth | `a9745a53` | 1 | 68 | 39 | 32 | 1 / 1 / 0 |
| reveal fix | `e610deda` | 1 | 65 | 36 | 32 | 1 / 1 / 0 |

The later fetched int11 head (`62d65ca6`) is outside smooth's ancestry; it was not merged or used as the integrated endpoint. The captures record the panel as the app's key window. The initial batch had 420 × 609 content geometry; later launches had 320 × 460. The earlier captures were repeated at 320 × 460. `reveal/count-bisect.json` references the final matched dataset; `reveal/count-geometry-check.json` verifies every hosting-root frame and native key-window state. The table above uses this final dataset. The separate Objective-C ordering counters for base, colour1, owner1 and int11 are unchanged: 10 appearance callbacks, 3 drawing-appearance scopes, 9 explicit CA commits, 1 token-field update and 0 Tasks body evaluations.

The source audit in `reveal/source-environment-audit.json` separates inputs from propagation counts. Across all six revisions there are eight `@ObservedObject` inputs to the sole panel root and zero `.environmentObject` injections. The panel has eight distinct direct environment-value writes across its shell/page tree, plus the design modifier's `atticDesign`, and the existing tint/accent modifiers. Colour1 adds one `atticTagColouring` value; the AR-06 native forwarding is in Notes hosts, none of which exist in this Tasks cold-reveal hierarchy. Both design and palette values already conform to Equatable/Hashable, and the appearance setter already skips an unchanged name. Adding more equality or appearance guards would not address the measured three-layer change.

The final baseline-versus-fixed count gate passes with every measured count equal: `reveal/base-fixed-uniform-count-gate.json`. The owner1-versus-int11 gate fails only on views and layers: `reveal/owner1-int11-uniform-count-gate.json`. The earlier 420 × 609 endpoint gate gives the same result and is retained as supplemental evidence.

The gates reject missing native counters, different hook/breakpoint coverage, mismatched settings and different native key-window states. The native XCTest regression compares the real rendered list against a single-mask reference rather than hard-coding a platform-wide layer total. Both fast and costs CI run the Python gate tests; fast also runs the native unit regression.

## Timing acceptance

The normal, uninstrumented optimized previews were built and measured, then quit by bundle ID. Their executable hashes and source revisions are in `reveal/timing-provenance.json`; `nm` confirms neither binary links the count overlay. Four pairs were declared in advance, alternating AB / BA / AB / BA (eight fresh launches), with 20 seconds settling and 60 seconds idle for each launch. The paired gate remains unchanged in its requirement: median candidate-minus-`76e4276` difference must be <= 0, with no millisecond allowance. Counts or debugger timings cannot substitute for this result.

| Pair / launch order | Reference ms | Candidate ms | Candidate minus reference ms |
|---|---:|---:|---:|
| 1 / AB | 61.847 | 66.491 | +4.644 |
| 2 / BA | 149.013 | 72.209 | -76.804 |
| 3 / AB | 84.593 | 40.665 | -43.928 |
| 4 / BA | 109.160 | 66.548 | -42.612 |

**Pass: median paired difference -43.270 ms.** Reference spread 87.166 ms, candidate spread 31.544 ms; one pair has a small positive difference. This is measured acceptance under the declared protocol, not a claim that every reveal is faster. All eight settled window captures are 752 × 1032 pixels (320 × 460 content plus the native margin at 2×); `reveal/timing-geometry-check.json` records the match. Raw results: `reveal/paired-reveal-gate.json` and `reveal/timing-p*/measurements.json`.

## Verification and evidence

- Strict-concurrency Local build/test: 25 OwnerTasks1010 tests passed; zero failures/skips. Includes the native count, scroll-identity and rendered overlap checks.
- TasksRound10Pager + TasksRound12: 28 passed; zero failures/skips. Includes native scroll restoration, page retention and rendered faint-edge checks. Fixture runtime warnings were recorded in `reveal/scroll-test-summary.json`; they were not suppressed.
- After adding positive reference-fixture assertions, the three focused mask tests passed again; zero failures/skips.
- Python gate/probe tests: 14 smooth + 5 reveal passed. Stale count/debugger output is now rejected before launch (red then green).
- Project-generation verification: passed using the installed Homebrew Ruby/Bundler. The first system-Ruby invocation could not load the required Bundler; no project input changed.
- Before captures: `reveal/count-base/panel.png`, `reveal/count-int11-uniform/panel.png`. Normal historical-base capture: `reveal/timing-p1-reference/panel.png`. Corrected captures under LLDB/count instrumentation (`reveal/count-fixed/panel-unsettled.png`, `reveal/count-fixed-uniform/panel-unpainted-diagnostic.png`) were blank and are excluded from visual acceptance. The diagnostic painting cause is unresolved; normal uninstrumented candidate captures render correctly. Settled normal-preview capture `reveal/timing-p1-candidate/panel.png` was inspected. The empty Tasks page renders correctly. The normal optimized preview was also launched with a disposable in-memory long Tasks fixture and pinned via its existing UI-test seam. Its populated list was inspected in `reveal/uat-seeded-tasks.png`, then the exact owned executable was rechecked and the preview quit by bundle ID before releasing the screen lock. Interactive composer/picker UAT is **not passed**: `cua.getApp` failed twice with "Sky Computer Use native pipe startup failed", including after reset. `reveal/uat-status.json` records the blocker. The rendered F-13 strip and scroll-identity behavior are independently covered by the passing native tests.
- Fast CI dispatched once: [38142622429](https://github.com/TesterPen0812/Attic/actions/runs/38142622429), **passed** on `8f132385`: build, strict concurrency, 2,588 unit tests passed / 10 skipped / 0 failed / 0 expected failures, native dropdown timing gates and static analysis.
- Costs CI dispatched once after fast completed: [38144984632](https://github.com/TesterPen0812/Attic/actions/runs/38144984632), **passed** on the same `8f132385` code commit: all 65 frame/row, integration and Done-query comparison rows passed on attempt 1, with no comparison re-check; candidate absolute budgets and all 11 Done-search tests passed (zero failures/skips). Full comparison table: `reveal/ci-costs-comparison.md`; final workflow and test summaries: `reveal/ci-costs-result.json`, `reveal/ci-costs-unit-summary.json`. The final report/evidence commit changes no executable source. No FKA lane is required because no keyboard-focus behavior changed.
- Local xcresults were summarized and moved to Trash; none remain in `.build`. Generated local output stayed at about 1.8 GB. Raw rejected diagnostic files are retained under `.build/reveal-raw`, outside the committed evidence set.

Initial diagnostic launches exposed errors in the overlay (unsafe class-list bridging and a main-actor assumption on the display-link thread); the overlay was corrected before accepted captures. Early broad regex counters counted a closure as well as the environment method. Initial design1 captures were excluded: one had unmatched native key state and another ordered before the commanded cold reveal. The repeat (`reveal/design1-order-trace/`) passes the count comparison and records a caller stack through the performance signal handler; it confirms a commanded cold reveal. The extra stack read occurred before enabling the native counters and is diagnostic only. These diagnostic attempts are not product regressions or acceptance evidence.

No protected owner app was launched, quit, captured or accessed. No macOS setting changed, no Canvas page was exercised, and dormant CloudKit/iPhone code was retained. The fresh stores and screenshots belong only to the authorized `com.taha.Attic.preview.phasex` preview. No other worktree was modified, no subagent ran, and no integration merge is performed. Hindsight tools were advertised but were not present in the callable tool inventory.
