# Deep Audit Batch 2 — Independent Review R3: Image Recovery Pipeline, Resource Usage and Efficiency

- **Reviewer:** independent review pass (this thread). No other reviewer's report or transcript was consulted.
- **Date:** 2026-09-15
- **Scope:** CVD-03 (retry requeues every failed image) and CVD-04 (retry for failed images outside the decode candidate set), plus decode/cache churn, memory bounds, unbounded growth, and lifecycle regressions on the image recovery path. Other Batch 2 fixes (undo routing, text refit, keyboard minimum) reviewed only where they intersect this surface.
- **Verdict: REVIEW_PASS** — no confirmed defects on the assigned surface.

## 1. Reviewed sources

Frozen snapshot `/tmp/attic-b2-snapshot-20260915T1845Z`, manifest SHA-256
`9af3fc17a070842e7ce8a4975cd66efa7b4ce5a3b297b79bfd5371a5380ca339` — verified
independently (`shasum -a 256 -c MANIFEST.sha256`, 598/598 files OK). Private
reconstruction at `/tmp/attic-b2-review-r3/tree` = `git archive
ae6418c1af690e29d15a20344cdb9765a23d3f85` + snapshot `worktree/` overlay;
diff against the live checkout showed only expected build/workspace artifacts
(`.build/`, `project.xcworkspace`). Live source and snapshot were never
modified; all builds used private DerivedData (`/tmp/attic-b2-review-r3/dd`,
`/tmp/attic-b2-review-r3/mut-dd`). No app launch, no native UI automation, no
commits.

SHA-256 of the files central to this review (fixed tree):

| File | SHA-256 |
| --- | --- |
| `Attic/Canvas/CanvasImageTypes.swift` | `40d1ff2687918c432a2f471b3f91660a5cecc96566aaddb6d52cb91dcc0ce954` |
| `Attic/Canvas/CanvasSurfaceRenderer.swift` | `48c81ecf1a1085ba8a98239e8c4e561959cbd284898e534f7227009a5f408b19` |
| `Attic/Canvas/CanvasSession.swift` | `c268412d6a25d33c910616823d1eef864b016bd935055443f21e83d688ea0c81` |
| `Attic/Canvas/CanvasSurfaceMacHelpers.swift` | `8f7fe9484ad96403776640f60fa059b41eafa6ab62ebfcd2e68f5be59839dbbc` |
| `AtticTests/CanvasDomainTests.swift` | `2777a07d58571a48de7c587f39bf646e2858f1e8fb5ce1a2fb07971b1d18562b` |
| `AtticTests/CanvasRenderCacheTests.swift` | `dac3e3aac349a2ee42288dbdd93feaf495b434b72e77781968eba4255b9f79fb` |

## 2. Commands run and results (all independent, on the private reconstruction)

Build: `xcodebuild build-for-testing -project Attic.xcodeproj -scheme Attic
-configuration Local -derivedDataPath /tmp/attic-b2-review-r3/dd
"-only-testing:AtticTests" CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO` —
succeeded. 6 warnings, all pre-existing test-file issues (deprecated
`CGWindowListCreateImage`, unreachable code); none in changed files.

Tests executed via the injected-xctest host runner (no IDE session):

| Run | Selection | Result |
| --- | --- | --- |
| `r3-new` | 2 new `CanvasAccessibilityTests` + 1 new `CanvasRenderCacheTests` | 3 tests, 0 failures (0.084s) |
| `r3-cache` | `CanvasRenderCacheTests`, `CanvasImageSessionTests`, `CanvasImageDomainTests`, `CanvasPerformanceGateTests` | 39 tests, 0 failures (4.25s) |
| `r3-canvas` | all 16 canvas test classes incl. performance gates | 205 tests, 0 failures (16.4s); log line: `Canvas decode stress: 96 images in 0.073s, max active 4` |
| `r3-mut-m2b` | mutant: `prepare` prunes queued retries (`retryKeys` honour removed) | 3 tests, **10 failures** — expected; proves the cache test discriminates the fix |
| `r3-mut-m1` | mutant: `retryFailedImageDecodes` sends only `ids.first` | 3 tests, **3 failures** in both domain tests — expected; proves domain tests discriminate CVD-03 |
| `r3-mixed` | reviewer-added probe `testR3MixedRetryCoversExactlyFailedSet` (mut-tree scratch copy) | 1 test, 0 failures (0.045s) |

Mutant diffs were applied to a scratch copy (`/tmp/attic-b2-review-r3/mut-tree`),
never to the reviewed tree. The M1/M2b failure signatures match the
implementation record's claims (M1 invisible to the cache unit test, M2b
invisible to the domain tests when a worker is free — both observed).

## 3. CVD-03 — retry requeues every failed image

**Mechanism.** `CanvasSession.retryFailedImageDecodes()`
(`CanvasSession.swift:383-388`) publishes
`CanvasImageDecodeRetryRequest(imageIDs:)` carrying
`Set(images.map(\.id)).intersection(failedImageIDs)` — exactly the live failed
set. Each request has a fresh `attemptID` (`CanvasImageTypes.swift`), so every
user click is a distinct consumable. The macOS bridge
(`CanvasSurfaceMac.swift:151-157`) consumes each request once per view
(`lastDecodeRetryRequest != request`), iterating `view.images` (the full image
list in z-order, not just candidates) and calling `imageCache.retryDecode` per
matching image.

**Exactly the failed set.** Double-guarded: (a) `setFailedImageIDs`
(`CanvasSession.swift:369-372`) only ever stores ids the surface reported as
`.failed`, intersected with live images; `synchronizeFromStore`
(`CanvasSession.swift:1693-1694`) re-intersects on every store sync, so
removed images can't linger; (b) `CanvasImageDecodeCache.retryDecode`
(`CanvasSurfaceRenderer.swift:174-181`) opens with
`guard failed.remove(key) != nil else { return }` — a request naming a
non-failed image is a no-op. My probe test confirmed a mixed board (1 corrupt +
1 decodable PNG) produces `request.imageIDs == {corrupt.id}` exactly and the
successful sibling stays `.ready` through the retry.

**No double-enqueue.** `enqueueIfNeeded`
(`CanvasSurfaceRenderer.swift:199-210`) refuses when already queued, already
cached, or an uncancelled active decode for the key exists. A second Retry
click while the first attempt is in flight re-publishes the same id set but
`failed.remove` returns nil — verified empirically in `r3-mixed`.

**No unbounded loop.** Nothing re-invokes `retryFailedImageDecodes`
automatically; the only callers are the banner button
(`CanvasPanelContent.swift:288`) and the per-image path
(`session.retryImageDecode`, `CanvasSurfaceMac.swift:108-110` /
`CanvasPanelContent.swift:692`). A permanently failing image costs one bounded
decode attempt per click and is re-memoized via `rememberFailure`. The
pre-existing `testDecodeFailureIsMemoizedAndRetryInvalidatesStablePlaceholder`
pins exactly 2 attempts for fail→retry→fail.

**Ordering.** `request.imageIDs` is a `Set`, but the bridge iterates
`view.images` in z-order, so retries enqueue in deterministic image order;
`queuedOrder` is FIFO within that. No ordering contract was broken (pre-fix
retried at most one image). Per-image reporting is preserved: each
`finishDecode` fires `onImageReady` → `onDecodeFailuresChanged` →
`setFailedImageIDs(Set(images.filter { state == .failed }.map(\.id)))`, and
`failedImageIDs` is a per-image `Set<UUID>`; the a11y retry action remains
per-image.

## 4. CVD-04 — retry outside the decode candidate set

**Candidate membership.** `CanvasImageDecodeCandidatePolicy.candidates` =
visible images plus the 192pt prefetch margin; `prepare`
(`CanvasSurfaceRenderer.swift:138-155`) filters `queued` to
`visibleKeys ∪ retryKeys` (line 142) and, when
`cancelsActiveDecodesWhenRemoved`, cancels active decodes not in
`visibleKeys ∪ retryKeys` (line 144). `retryDecode` inserts the key into
`retryKeys` iff the image is outside `visibleKeys` at retry time and a queue
entry was created (line 179). `finishDecode` keeps the result when `retried`
even off-screen (lines 282, 291-292) and clears the key. `removeAll` clears
`retryKeys` along with everything else.

**Verified.** `r3-new` passes the new
`testRetryDecodeRequeuesOffScreenFailureAcrossCandidatePruning` under **both**
`cancelsActiveDecodesWhenRemoved` values; the test shows the off-screen retry
stays `.queued` across repeated `prepare` prunes while a worker is occupied
(bounded concurrency respected — the retry cannot bypass
`active.count < maximumConcurrentDecodes`), then runs and recovers
(`[70, 71, 70]` attempt order). M2b (restoring the old prune) fails the test
with 10 assertion failures — independently reproduced. The domain test
`testRetryFailedImageDecodesRequeuesOffScreenFailure` proves end-to-end: an
image failed while on-screen, panned 3000pt away, retried via the banner path,
re-fails and is re-reported in `failedImageIDs`.

## 5. Decode/cache churn and memory (measured vs inferred)

**Measured.** Decode-stress gate on my build: 96 images in 0.073s, max active 4
(matches the implementation record's 0.074s/4). All 20
`CanvasPerformanceGateTests` passed inside `r3-cache`/`r3-canvas`. No new
timers, polling, or background work was added — retries are strictly
user-initiated.

**Inferred (structural).**
- `DecodeRequest` retains `image.encodedData`; those `Data` are already
  resident in `session.images`, so a queued off-screen retry adds only the
  request struct — no new payload faulting or duplication.
- Retried off-screen results are kept in the same `NSCache` bounded by
  `totalCostLimit = 256MB` / `countLimit = 48` — the hero-image invariant is
  preserved; a retried hero cannot exceed the shared cost/count budget.
- Failure state is bounded by `failedDecodeLimit = 512`
  (`trimFailureHistory`, lines 316-327), with visible failures protected from
  eviction; failure records store content-token `UUID`s, not payloads.
- `retryKeys` is bounded by the number of remembered failures and is drained
  on `finishDecode`/`removeAll`; `queuedOrder` growth is compacted
  (`compactQueueIfNeeded`, lines 265-273) and fully rebuilt each `prepare`.
- Per-attempt allocations: one `Task` + one `DecodeRequest` per click-driven
  attempt; no accumulation across attempts.

## 6. Regression surface

- **Import / batch cancellation:** `imageImportTasks` and
  `cancelAllImageImportBatches` (`CanvasSession.swift:360-367`) are disjoint
  from the decode cache; no interaction introduced.
- **Board switch / teardown:** canvas-ID changes call `imageCache.removeAll()`
  (clears queued/active/failed/failedOrder/retryKeys/cache); view `deinit`
  cancels active tasks. `synchronizeFromStore` intersects `failedImageIDs`
  with live images. A stale `imageDecodeRetryRequest` surviving a board
  switch is a bounded no-op — its ids can't match the new board's images, and
  `failed.remove` would no-op regardless.
- **Candidate churn:** `prepare` still runs the same enqueue/prune cycle; the
  only predicate change is the `|| retryKeys.contains` escape for explicit
  retries.
- **iOS:** `CanvasSurfaceIOS` does not consume `imageDecodeRetryRequest`
  (unchanged — deferred platform, not a claim of iOS behavior).

## 7. Confirmed defects

None.

## 8. Suspicions / observations (not blocking)

1. **Retry of a just-panned-away image can be silently dropped.** `retryKeys`
   membership is decided by `!visibleKeys.contains(key)` at `retryDecode` time
   (`CanvasSurfaceRenderer.swift:179`). A *visible* failed image that is
   retried and then leaves the candidate set before a worker frees has its
   queued entry pruned (not in `retryKeys`) and its failure record already
   removed → state `.idle`, banner may transiently under-report until the next
   `onImageReady`. Self-heals on scroll-back (fresh enqueue → re-fail → banner
   returns). Pre-fix semantics for the visible path were identical, so this is
   not a regression introduced by Batch 2 — but the fix's "sticky retry"
   coverage only applies to images already off-set at click time.
   *Unverified limit:* not exercised under native pan timing; reasoning only.
2. **`imageDecodeRetryRequest` is never cleared** on the session. A recreated
   view replays the last request once (`lastDecodeRetryRequest` is per-view);
   each replayed `retryDecode` is a `failed.remove` no-op unless the image
   genuinely re-failed. Bounded, harmless, arguably resilient.
3. **`retryImageDecode(_:)` doesn't check `failedImageIDs`** — relies entirely
   on the cache-side `failed.remove` guard. Consistent with the documented
   contract; noted for completeness.

## 9. Optional improvements

- Insert retried keys into `retryKeys` unconditionally (not only when
  currently off-set) so an explicit user retry survives any later candidate
  change until it runs — closes observation 1 at trivial cost.
- Assert `session.imageDecodeRetryRequest?.imageIDs` equals the exact failed
  set in a domain test (my probe did this; the merged suite asserts behavior
  only).
- Optionally clear `imageDecodeRetryRequest` in `synchronizeFromStore` on
  board changes for tidiness.

## 10. Verdict

**REVIEW_PASS.** The CVD-03/CVD-04 implementation is correct, bounded, and
discriminatingly tested; my independent runs (3/3, 39/39, 205/0, decode stress
0.073s/max-4) match the implementation record, and both negative-control
mutants reproduced the expected failure signatures. No resource regressions:
no new background work, unchanged concurrency and NSCache bounds, failure and
retry state all bounded.

**Limits:** local unit/integration evidence only — no app launch, no native or
physical-input UAT, no CloudKit/APNs/iPhone claims. Not covered: long-horizon
soak of repeated pan+retry cycles under memory pressure (structural bounds
argue safety; not measured).

**Elapsed:** ~35 minutes of active verification (private reconstruction
19:52→20:26 local), within budget.
