# Attic static audit (in progress)

Target: `review/pro-13nov`, commit `42f9b5707d06f78c0c6bc3fb99d135d6f38fcb44`. Static review in Linux only; no macOS build, runtime, or UI validation. Root `AGENTS.md`, `README.md`, and `Docs/README.md` read first. Dormant iPhone and CloudKit work is excluded from dead-code findings and removals. No changes to app code or user data.

## Coverage and checkpoint

Inventory: 375 Swift files under Attic, 259 under AtticTests/AtticUITests, 807 files total across Attic, tests, Scripts and .github. Counted with `find`. Initial searches covered type names, asset filenames and build flags, but this is not an exhaustive audit. Detailed inspection so far: development contract, resources inventory, Draw metadata/search paths, Calendar agenda/search pipeline, HTTP request parser, agent-server lifecycle and partial script/CI test discovery. All other areas remain to review. No completion or absence-of-bugs claim is justified.

## Part 1: dead code

No safe removal has yet been established. An automated identifier-frequency pass initially highlighted `CanvasStrokeCountLabel` (Attic/Canvas/CanvasControls.swift:135–150, 16 lines), but the identifier `canvas-stroke-count` is referenced by `AtticMobileUITests/CanvasMobileUITests.swift:72`. Because mobile is deliberately dormant, this is not reported or removed as dead code. Likewise `AtticMotion`, `TaskStatusMark`, and `CanvasToolControls` have mobile references and are retained. Exact searches: `rg -n -w 'CanvasStrokeCountLabel' .` and `rg -n 'canvas-stroke-count|CanvasStrokeCountLabel' --hidden -g '!.git/**' .`. A lexical count cannot establish dynamic or generated references.

## Part 2: lightness

### LT-1: Draw search eagerly fetches every canvas thumbnail
- `Attic/Draw/DrawStore.swift:131–142`; `Attic/Draw/DrawPersistentStore.swift:146–155, 518–526`.
- `search` calls `library()` before filtering. Persistent `library()` fetches all canvas records and invokes `thumbnail(for:)` for every winning row; that issues a separate payload fetch and reads its bytes. A search therefore pays for thumbnails even for unmatched canvases, before the search UI calls `showThumbnails()` for results. Split metadata-only search from thumbnail loading and load thumbnails for visible results, preserving replica winner logic and error handling.
- Estimated gain: for N canvases with thumbnails, avoid up to N thumbnail queries and the sum of their byte reads on each uncached search, replacing them with reads for visible results. Actual latency and memory savings require measurement on a Mac with representative data.
- Risk: medium. Preserve thumbnail correctness, duplicate-replica selection, scrolling and accessibility; add repository metrics tests and measure cold/warm paths.

### LT-2: Calendar searches scan the entire 10,000-year date domain
- `Attic/Calendar/UI/CalendarAgenda.swift:212–219`; `Attic/Calendar/Data/EventKitCalendarEventSource.swift:86–87, 188–198, 273–299`; `Attic/Calendar/UI/CalendarPageModel.swift:409–431`.
- Every new query searches years 1 through 9999, divided into fixed three-year intervals. The worker queues a query for every span, even with no matching events, and recurring events can generate many snapshots retained in `seen` and `matches`. Nearby spans are processed first and cancellation is supported, which mitigates responsiveness but does not bound work if a search is left open. Preserve the complete-domain requirement while investigating an indexed, incremental or user-controlled deep search rather than silently removing historical results.
- Estimated gain: a completed search currently requires about 3,336 EventKit span queries; a cached local index or bounded first pass could avoid most repeated queries. CPU, elapsed time and memory gains are unmeasured and depend on EventKit and the user's calendars. Measure before choosing a design.
- Risk: medium/high. Must retain old/future event discoverability, recurring-event correctness, permissions, cancellation and fresh results. Add a fake-store query-count test and profile representative recurring calendars on a Mac.

### Size baseline, not a finding
`find Attic/Resources -type f -printf '%s %p\\n' | sort -nr` reports the largest individual resource as `Sounds/done.wav` at 28,844 bytes; the entire `Attic/Resources` directory is about 308 KiB on this checkout (`du -sh`). WAV cues are loaded by enum raw value in `Attic/Services/AtticSounds.swift:103–111`, so a literal filename search alone would falsely label them unused. These filesystem numbers are not a built app size or compressed bundle measurement.

## Script test checkpoint

Ran `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Scripts -p 'test_*.py'` on Linux. The runner reported 173 tests and one setup error, with no assertion failures reported: `test_cost_gate_plumbing.CostGatePlumbingTests.setUpClass` requires `xcrun`, which is unavailable on this non-Mac host. The shell wrapper then printed the log and returned 0, so that wrapper exit status must not be mistaken for a passing suite. Mac-only tests and this class remain unverified. Test discovery globs in `.github/workflows/macos-ci.yml:294–301, 863–868` show why lack of an exact filename reference is not proof that a Python test is unused. A hash scan found duplicate fixture bytes, but no evidence those fixtures can be merged safely; retained.

## Part 3: bugs

### DB-1 (P2): Agent week strip can block the main thread on EventKit
- `Attic/App/AppCoordinator.swift:669–679`, `Attic/Agent/AgentChatModel.swift:1382–1388, 1481–1492`, `Attic/Calendar/Data/EventKitCalendarEventSource.swift:134–136, 201–203, 253`.
- Trigger: with Calendar access granted, an agent run reads Calendar or presents a move to another week while the EventKit read worker is slow or busy. The chat model requests its week synchronously on the main actor. The coordinator calls `events(in:)`, whose compatibility path calls `queue.sync` and waits for the worker's EventKit read. The UI can therefore stop responding for the duration of that read or an earlier queued read. The delay's magnitude has not been measured on a Mac.
- Smallest fix: make the week fetch asynchronous, initially show task/empty-week content, and apply event bars when the current run and week still match. Reuse the existing async event reader; guard against stale results when the target changes.
- Confidence: high for the synchronous blocking path, medium for real-world perceptibility. Existing AgentChat tests inject immediate synchronous `weekDays` closures and do not establish nonblocking EventKit behavior.
- Red test: provide a fake Calendar reader whose read stays suspended, trigger the week strip, and assert a main-actor heartbeat and chat interaction continue before releasing the reader; then assert the correct week receives its results and a stale week does not.

Initial force-unwrap and HTTP parser searches are leads only, not findings.

## Summary at this checkpoint
- Dead code confirmed: 0. Removed: 0. No removal branch created.
- Lightness opportunities: 2; LT-1 and LT-2 are preliminary, not a ranked top 10.
- Bugs: 2 static findings (DB-1 and DB-2); runtime effect remains unmeasured. This is not a complete bug inventory.
- Mac checks: build and relevant tests, plus profiling of Draw search and thumbnail loading and Calendar search before and after any proposed change, and DB-1 with a deliberately slow EventKit source.
- Remaining: exhaustive symbol and dynamic-reference analysis; assets/scripts/tests/CI; launch and lifetime review; the full bug hunt across all requested areas. In particular, no folder has been read fully file by file.
