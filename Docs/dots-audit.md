# Attic static audit (in progress)

Target: `review/pro-13nov`, commit `42f9b5707d06f78c0c6bc3fb99d135d6f38fcb44`. Static review in Linux only; no macOS build, runtime, or UI validation. Root `AGENTS.md`, `README.md`, and `Docs/README.md` read first. Dormant iPhone and CloudKit work is excluded from dead-code findings and removals. No changes to app code or user data.

## Coverage and checkpoint

Inventory: 375 Swift files under Attic, 259 under AtticTests/AtticUITests, 807 files total across Attic, tests, Scripts and .github. Counted with `find`. Initial searches covered type names, asset filenames and build flags, but this is not an exhaustive audit. Detailed inspection so far: development contract, resources inventory, Draw metadata/search paths, HTTP request parser and part of agent-server lifecycle. All other areas remain to review. No completion or absence-of-bugs claim is justified.

## Part 1: dead code

No safe removal has yet been established. An automated identifier-frequency pass initially highlighted `CanvasStrokeCountLabel` (Attic/Canvas/CanvasControls.swift:135–150, 16 lines), but the identifier `canvas-stroke-count` is referenced by `AtticMobileUITests/CanvasMobileUITests.swift:72`. Because mobile is deliberately dormant, this is not reported or removed as dead code. Likewise `AtticMotion`, `TaskStatusMark`, and `CanvasToolControls` have mobile references and are retained. Exact searches: `rg -n -w 'CanvasStrokeCountLabel' .` and `rg -n 'canvas-stroke-count|CanvasStrokeCountLabel' --hidden -g '!.git/**' .`. A lexical count cannot establish dynamic or generated references.

## Part 2: lightness

### LT-1: Draw search eagerly fetches every canvas thumbnail
- `Attic/Draw/DrawStore.swift:131–142`; `Attic/Draw/DrawPersistentStore.swift:146–155, 518–526`.
- `search` calls `library()` before filtering. Persistent `library()` fetches all canvas records and invokes `thumbnail(for:)` for every winning row; that issues a separate payload fetch and reads its bytes. A search therefore pays for thumbnails even for unmatched canvases, before the search UI calls `showThumbnails()` for results. Split metadata-only search from thumbnail loading and load thumbnails for visible results, preserving replica winner logic and error handling.
- Estimated gain: for N canvases with thumbnails, avoid up to N thumbnail queries and the sum of their byte reads on each uncached search, replacing them with reads for visible results. Actual latency and memory savings require measurement on a Mac with representative data.
- Risk: medium. Preserve thumbnail correctness, duplicate-replica selection, scrolling and accessibility; add repository metrics tests and measure cold/warm paths.

### Size baseline, not a finding
`find Attic/Resources -type f -printf '%s %p\\n' | sort -nr` reports the largest individual resource as `Sounds/done.wav` at 28,844 bytes; the entire `Attic/Resources` directory is about 308 KiB on this checkout (`du -sh`). WAV cues are loaded by enum raw value in `Attic/Services/AtticSounds.swift:103–111`, so a literal filename search alone would falsely label them unused. These filesystem numbers are not a built app size or compressed bundle measurement.

## Part 3: bugs

No bug has yet been validated to the required evidence standard. Initial force-unwrap and HTTP parser searches are leads only, not findings.

## Summary at this checkpoint
- Dead code confirmed: 0. Removed: 0. No removal branch created.
- Lightness opportunities: 1; LT-1 is the only candidate so far, not a ranked top 10.
- Validated bugs: 0; this does not mean there are none.
- Mac checks: build and relevant tests, plus profiling of Draw search and thumbnail loading before and after any proposed change.
- Remaining: exhaustive symbol and dynamic-reference analysis; assets/scripts/tests/CI; launch and lifetime review; the full bug hunt across all requested areas. In particular, no folder has been read fully file by file.
